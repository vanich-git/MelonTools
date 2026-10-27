//! Fast quota guard. Passive gateway headers are the primary signal; the
//! provider usage endpoint is only the fallback and reset probe.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::gateway::{self, ManagementAuthFile, ManagementAuthSnapshot};
use crate::settings::Settings;
use crate::vault::{self, Account, Quota, QuotaBlock, APPLE_REF_UNIX_OFFSET};

const LIVE_MAX_AGE: f64 = 120.0;
const USAGE_MAX_AGE: f64 = 1800.0;
/// Live readings are written once per this interval unless a block changes.
/// The previous code rewrote the whole vault (and DPAPI tokens) every 1.5 s.
const PERSIST_INTERVAL: Duration = Duration::from_secs(45);

static LAST_TICK_MS: AtomicU64 = AtomicU64::new(0);
static LAST_PERSIST: OnceLock<Mutex<Instant>> = OnceLock::new();
static PENDING_QUOTAS: OnceLock<Mutex<HashMap<String, (Quota, f64)>>> = OnceLock::new();

fn last_persist() -> &'static Mutex<Instant> {
    LAST_PERSIST.get_or_init(|| Mutex::new(Instant::now() - PERSIST_INTERVAL))
}

fn pending_quotas() -> &'static Mutex<HashMap<String, (Quota, f64)>> {
    PENDING_QUOTAS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Last completed live-guard tick, exposed to `gateway_status` so a regression
/// in this loop is visible without a profiler.
pub fn last_tick_ms() -> u64 {
    LAST_TICK_MS.load(Ordering::Relaxed)
}

#[derive(Clone, Debug, Default, PartialEq)]
struct ResetProbeState {
    next: Option<Instant>,
    failures: u32,
    in_flight: bool,
}

static RESET_PROBES: OnceLock<Mutex<HashMap<String, ResetProbeState>>> = OnceLock::new();

fn reset_probes() -> &'static Mutex<HashMap<String, ResetProbeState>> {
    RESET_PROBES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// One guard cycle. The caller runs this on a 1.5-second tokio interval in a
/// native task, so WebView timer throttling cannot stop quota enforcement.
pub async fn tick(settings: &Settings) {
    let started = Instant::now();
    // One snapshot per tick. `reconcile_and_apply` used to read the vault two
    // more times (plus once inside the reset-probe scan) on every tick.
    let accounts = vault::accounts();
    let snapshot = gateway::management_auth_files(settings).await.ok();
    let (accounts, updates, block_updates) =
        reconcile_and_apply(settings, accounts, snapshot.as_ref()).await;

    queue_quota_updates(updates);
    if !block_updates.is_empty() {
        flush_quota_updates(Some(&block_updates));
    } else {
        flush_quota_updates(None);
    }

    let due = due_reset_probes(&accounts, snapshot.as_ref());
    for id in due {
        let settings = settings.clone();
        let account = accounts.iter().find(|account| account.id == id).cloned();
        tokio::spawn(async move {
            let result = if let (Some(account), Ok(client)) = (account, crate::quota::client()) {
                crate::quota::refresh_one(&client, &account).await
            } else {
                Err("quota reset probe unavailable".to_string())
            };
            record_probe_result(&id, result.is_ok());
            let snapshot = gateway::management_auth_files(&settings).await.ok();
            let accounts = vault::accounts();
            let (_, updates, block_updates) =
                reconcile_and_apply(&settings, accounts, snapshot.as_ref()).await;
            queue_quota_updates(updates);
            if !block_updates.is_empty() {
                flush_quota_updates(Some(&block_updates));
            } else {
                flush_quota_updates(None);
            }
        });
    }
    LAST_TICK_MS.store(started.elapsed().as_millis() as u64, Ordering::Relaxed);
}

fn queue_quota_updates(updates: Vec<(String, Quota, f64)>) {
    if updates.is_empty() {
        return;
    }
    if let Ok(mut pending) = pending_quotas().lock() {
        for (id, quota, observed_at) in updates {
            pending.insert(id, (quota, observed_at));
        }
    }
}

/// Persist queued readings at most every [`PERSIST_INTERVAL`]. Block changes
/// pass `blocks` and force an immediate write: routing must pause before the
/// next request, while a percent display can wait.
fn flush_quota_updates(blocks: Option<&[(String, Option<QuotaBlock>)]>) {
    let due = blocks.is_some()
        || last_persist()
            .lock()
            .map(|last| last.elapsed() >= PERSIST_INTERVAL)
            .unwrap_or(false);
    if !due {
        return;
    }
    let updates: Vec<(String, Quota, f64)> = pending_quotas()
        .lock()
        .map(|mut pending| {
            pending
                .drain()
                .map(|(id, (quota, at))| (id, quota, at))
                .collect()
        })
        .unwrap_or_default();
    if updates.is_empty() && blocks.map_or(true, |blocks| blocks.is_empty()) {
        return;
    }
    if vault::apply_live_updates(&updates, blocks.unwrap_or(&[])).is_ok() {
        if let Ok(mut last) = last_persist().lock() {
            *last = Instant::now();
        }
    }
}

async fn reconcile_and_apply(
    settings: &Settings,
    mut accounts: Vec<Account>,
    snapshot: Option<&ManagementAuthSnapshot>,
) -> (
    Vec<Account>,
    Vec<(String, Quota, f64)>,
    Vec<(String, Option<QuotaBlock>)>,
) {
    let now_ref = vault::now_ref();
    let now_unix = now_ref + APPLE_REF_UNIX_OFFSET;
    let files = snapshot
        .map(ManagementAuthSnapshot::codex_files)
        .unwrap_or_default();
    let mut updates: Vec<(String, Quota, f64)> = Vec::new();
    let mut block_updates: Vec<(String, Option<QuotaBlock>)> = Vec::new();

    for (index, account) in accounts.iter_mut().enumerate() {
        let file = auth_file(account, index, &files);
        if let Some(file) = file {
            if let Some(reading) = crate::quota::parse_live_signals(
                &file.signals,
                file.observed_at.as_deref(),
                now_unix,
            ) {
                let observed_unix = reading.observed_at + APPLE_REF_UNIX_OFFSET;
                if observed_unix <= now_unix + 5.0 && now_unix - observed_unix <= LIVE_MAX_AGE {
                    // A passive signal captured before the last usage probe
                    // must not overwrite a newer reset reading. This matters
                    // right after a window resets: the old header still says
                    // 0%, while `/wham/usage` already reports 100%.
                    let stale_for_cache = account
                        .quota_updated_at
                        .map(|cached| reading.observed_at < cached - 0.5)
                        .unwrap_or(false)
                        && account.quota_source.as_deref() == Some("usage");
                    if !stale_for_cache {
                        merge_reading(account, &reading.quota, reading.observed_at);
                        updates.push((
                            account.id.clone(),
                            reading.quota.clone(),
                            reading.observed_at,
                        ));
                    }
                }
            }
        }

        let old_block = account.quota_block.clone();
        account.quota_block = reconcile_block(account, now_ref, now_unix);
        if old_block != account.quota_block {
            block_updates.push((account.id.clone(), account.quota_block.clone()));
        }
    }

    // Apply the small status patch first. A failed or unverified patch falls
    // back to the diff-based auth sync; unrelated credentials stay untouched.
    let mut fallback = snapshot.is_none() && !block_updates.is_empty();
    if snapshot.is_some() {
        for (index, account) in accounts.iter().enumerate() {
            let Some(file) = auth_file(account, index, &files) else {
                if account.is_blocked() {
                    fallback = true;
                }
                continue;
            };
            // A legacy disabled auth file remains disabled until a fresh
            // reading confirms recovery. Do not let stale cache lift it.
            let desired = account.is_blocked()
                || (file.disabled && account.quota_block.is_none() && !is_fresh(account, now_ref));
            if desired == file.disabled {
                continue;
            }
            if !gateway::set_auth_disabled(settings, file, desired).await {
                fallback = true;
            }
        }
    }
    if fallback {
        let _ = gateway::sync_accounts(settings);
    }
    (accounts, updates, block_updates)
}

fn merge_reading(account: &mut Account, reading: &Quota, observed_at: f64) {
    let mut quota = account.quota.clone().unwrap_or_default();
    if reading.hourly_remaining_percent.is_some() {
        quota.hourly_remaining_percent = reading.hourly_remaining_percent;
        quota.hourly_window_present = reading.hourly_window_present;
    }
    if reading.weekly_remaining_percent.is_some() {
        quota.weekly_remaining_percent = reading.weekly_remaining_percent;
        quota.weekly_window_present = reading.weekly_window_present;
    }
    if reading.hourly_reset_at.is_some() {
        quota.hourly_reset_at = reading.hourly_reset_at;
    }
    if reading.weekly_reset_at.is_some() {
        quota.weekly_reset_at = reading.weekly_reset_at;
    }
    if reading.hourly_window_minutes.is_some() {
        quota.hourly_window_minutes = reading.hourly_window_minutes;
    }
    if reading.weekly_window_minutes.is_some() {
        quota.weekly_window_minutes = reading.weekly_window_minutes;
    }
    account.quota = Some(quota);
    account.quota_updated_at = Some(observed_at);
    account.quota_source = Some("gateway".to_string());
}

fn is_fresh(account: &Account, now_ref: f64) -> bool {
    let Some(updated) = account.quota_updated_at else {
        return false;
    };
    let max_age = if account.quota_source.as_deref() == Some("gateway") {
        LIVE_MAX_AGE
    } else {
        USAGE_MAX_AGE
    };
    now_ref - updated >= -5.0 && now_ref - updated <= max_age
}

fn reserve_enabled(account: &Account, code: &str) -> bool {
    match code {
        "hourly_reserve" => account.hourly_reserve_percent.unwrap_or(0) > 0,
        "weekly_reserve" => account.weekly_reserve_percent.unwrap_or(0) > 0,
        _ => true,
    }
}

fn recovered(block: &QuotaBlock, account: &Account) -> bool {
    let Some(quota) = account.quota.as_ref() else {
        return false;
    };
    let (remaining, floor) = match block.code.as_str() {
        "hourly_exhausted" => (quota.hourly_remaining_percent, 0.0),
        "weekly_exhausted" => (quota.weekly_remaining_percent, 0.0),
        "hourly_reserve" => (
            quota.hourly_remaining_percent,
            block.limit.unwrap_or(0) as f64,
        ),
        "weekly_reserve" => (
            quota.weekly_remaining_percent,
            block.limit.unwrap_or(0) as f64,
        ),
        _ => return true,
    };
    remaining.is_some_and(|value| value > floor)
}

fn cause(account: &Account) -> Option<(&'static str, f64, Option<i64>, Option<f64>)> {
    let quota = account.quota.as_ref()?;
    if let Some(remaining) = quota.hourly_remaining_percent.filter(|value| *value <= 0.0) {
        return Some(("hourly_exhausted", remaining, None, quota.hourly_reset_at));
    }
    if let Some(remaining) = quota.weekly_remaining_percent.filter(|value| *value <= 0.0) {
        return Some(("weekly_exhausted", remaining, None, quota.weekly_reset_at));
    }
    if let (Some(limit), Some(remaining)) = (
        account.hourly_reserve_percent,
        quota.hourly_remaining_percent,
    ) {
        if limit > 0 && remaining <= limit as f64 {
            return Some((
                "hourly_reserve",
                remaining,
                Some(limit),
                quota.hourly_reset_at,
            ));
        }
    }
    if let (Some(limit), Some(remaining)) = (
        account.weekly_reserve_percent,
        quota.weekly_remaining_percent,
    ) {
        if limit > 0 && remaining <= limit as f64 {
            return Some((
                "weekly_reserve",
                remaining,
                Some(limit),
                quota.weekly_reset_at,
            ));
        }
    }
    None
}

fn reconcile_block(account: &Account, now_ref: f64, now_unix: f64) -> Option<QuotaBlock> {
    if let Some(block) = &account.quota_block {
        if !reserve_enabled(account, &block.code) {
            // Removing a reserve setting is an explicit user action.
        } else {
            let mut effective = block.clone();
            match effective.code.as_str() {
                "hourly_reserve" => effective.limit = account.hourly_reserve_percent,
                "weekly_reserve" => effective.limit = account.weekly_reserve_percent,
                _ => {}
            }
            if is_fresh(account, now_ref) && recovered(&effective, account) {
                // A fresh reading above the exact threshold (or above zero for an
                // exhausted window) is the only automatic lift condition.
            } else {
                return Some(effective);
            }
        }
    }
    if !is_fresh(account, now_ref) {
        return None;
    }
    let (code, remaining, limit, reset_at) = cause(account)?;
    Some(QuotaBlock {
        code: code.to_string(),
        remaining,
        limit,
        reset_at,
        blocked_at: now_unix,
        source: account.quota_source.clone(),
    })
}

fn auth_file<'a>(
    account: &Account,
    index: usize,
    files: &[&'a ManagementAuthFile],
) -> Option<&'a ManagementAuthFile> {
    if let Some(email) = account.email.as_deref().filter(|email| !email.is_empty()) {
        let matches: Vec<_> = files
            .iter()
            .copied()
            .filter(|file| {
                file.email
                    .as_deref()
                    .is_some_and(|value| value.eq_ignore_ascii_case(email))
            })
            .collect();
        if matches.len() == 1 {
            return matches.first().copied();
        }
    }
    let expected = gateway::auth_file_name(account, index);
    files.iter().copied().find(|file| file.name == expected)
}

fn due_reset_probes(
    accounts: &[Account],
    snapshot: Option<&ManagementAuthSnapshot>,
) -> Vec<String> {
    let files = snapshot
        .map(ManagementAuthSnapshot::codex_files)
        .unwrap_or_default();
    let now_ref = vault::now_ref();
    let now_unix = now_ref + APPLE_REF_UNIX_OFFSET;
    let now = Instant::now();
    let mut due = Vec::new();
    let Ok(mut states) = reset_probes().lock() else {
        return due;
    };
    for (index, account) in accounts.iter().enumerate() {
        let disabled = auth_file(account, index, &files).is_some_and(|file| file.disabled);
        let needs_probe = if let Some(block) = &account.quota_block {
            match block.reset_at {
                Some(reset) => now_ref >= reset,
                None => now_unix - block.blocked_at >= 60.0,
            }
        } else {
            disabled && !is_fresh(account, now_ref)
        };
        if !needs_probe {
            continue;
        }
        let state = states.entry(account.id.clone()).or_default();
        if state.in_flight {
            continue;
        }
        if state.next.is_some_and(|next| now < next) {
            continue;
        }
        let seconds = (8u64.saturating_mul(1u64 << state.failures.min(3))).min(60);
        state.next = Some(now + Duration::from_secs(seconds));
        state.in_flight = true;
        due.push(account.id.clone());
    }
    due
}

fn record_probe_result(id: &str, ok: bool) {
    if let Ok(mut states) = reset_probes().lock() {
        let state = states.entry(id.to_string()).or_default();
        state.in_flight = false;
        if ok {
            state.failures = 0;
            state.next = Some(Instant::now() + Duration::from_secs(30));
        } else {
            state.failures = state.failures.saturating_add(1).min(4);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{cause, reconcile_block, recovered};
    use crate::vault::{Account, Quota, QuotaBlock};

    #[test]
    fn exact_reserve_threshold_blocks_without_margin() {
        let mut account = Account::default();
        account.hourly_reserve_percent = Some(2);
        account.quota_updated_at = Some(crate::vault::now_ref());
        account.quota_source = Some("gateway".to_string());
        let mut quota = Quota::default();
        quota.hourly_remaining_percent = Some(2.0);
        account.quota = Some(quota);
        assert_eq!(cause(&account).unwrap().0, "hourly_reserve");
        assert_eq!(
            reconcile_block(&account, crate::vault::now_ref(), crate::vault::unix_now())
                .unwrap()
                .remaining,
            2.0
        );
    }

    #[test]
    fn reading_above_exact_threshold_recovers_but_stale_reading_does_not() {
        let mut account = Account::default();
        account.quota_source = Some("gateway".to_string());
        account.quota_updated_at = Some(crate::vault::now_ref());
        account.hourly_reserve_percent = Some(2);
        let mut quota = Quota::default();
        quota.hourly_remaining_percent = Some(2.01);
        account.quota = Some(quota);
        let block = QuotaBlock {
            code: "hourly_reserve".to_string(),
            remaining: 2.0,
            limit: Some(2),
            ..QuotaBlock::default()
        };
        account.quota_block = Some(block.clone());
        assert!(recovered(&block, &account));
        account.quota_updated_at = Some(crate::vault::now_ref() - 121.0);
        assert_eq!(
            reconcile_block(&account, crate::vault::now_ref(), crate::vault::unix_now()),
            Some(block)
        );
    }
}
