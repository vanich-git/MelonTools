//! Quota refresh against the ChatGPT backend, plus OAuth token refresh.

use reqwest::Client;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

use crate::vault::{self, now_ref, Account, Quota, Tokens, APPLE_REF_UNIX_OFFSET};

const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const TOKEN_ENDPOINT: &str = "https://auth.openai.com/oauth/token";
const USAGE_ENDPOINT: &str = "https://chatgpt.com/backend-api/wham/usage";
const RESET_CREDITS_ENDPOINT: &str =
    "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
const CONSUME_RESET_CREDIT_ENDPOINT: &str =
    "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume";
const USER_AGENT: &str = "Codex Desktop (Windows)";
const ORIGINATOR: &str = "Codex Desktop";
const WEB_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36";

static SHARED_CLIENTS: OnceLock<Mutex<HashMap<String, Client>>> = OnceLock::new();
static RESET_IN_FLIGHT: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

/// Client for loopback gateway calls; never follows the upstream proxy.
pub fn local_client() -> Result<Client, String> {
    crate::proxy::local(Client::builder())
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())
}

pub fn client() -> Result<Client, String> {
    let key = crate::proxy::active_url().unwrap_or_default();
    let cache = SHARED_CLIENTS.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some(client) = guard.get(&key) {
            return Ok(client.clone());
        }
    }
    let client = crate::proxy::apply(Client::builder())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    if let Ok(mut guard) = cache.lock() {
        guard.insert(key, client.clone());
    }
    Ok(client)
}

pub async fn refresh_tokens(client: &Client, account: &Account) -> Result<Tokens, String> {
    let refresh = account
        .tokens
        .refresh_token
        .clone()
        .filter(|t| !t.is_empty())
        .ok_or_else(|| "нет refresh_token — войдите в аккаунт заново".to_string())?;
    let body = serde_json::json!({
        "client_id": CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh,
    });
    let resp = client
        .post(TOKEN_ENDPOINT)
        .header("User-Agent", USER_AGENT)
        .header("originator", ORIGINATOR)
        .json(&body)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!(
            "refresh {}: {}",
            status.as_u16(),
            text.chars().take(200).collect::<String>()
        ));
    }
    let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let tokens = Tokens {
        id_token: value
            .get("id_token")
            .and_then(|v| v.as_str())
            .map(String::from)
            .or_else(|| account.tokens.id_token.clone()),
        access_token: value
            .get("access_token")
            .and_then(|v| v.as_str())
            .map(String::from),
        refresh_token: value
            .get("refresh_token")
            .and_then(|v| v.as_str())
            .map(String::from)
            .or(Some(refresh)),
        account_id: account.tokens.account_id.clone(),
    };
    if tokens.access_token.is_none() {
        return Err("в ответе нет access_token".to_string());
    }
    Ok(tokens)
}

/// Fresh tokens for the account (refreshing and persisting them when needed).
pub async fn ensure_fresh(client: &Client, account: &Account) -> Result<Tokens, String> {
    if !account.tokens.needs_refresh() {
        if let Some(access) = &account.tokens.access_token {
            if !access.is_empty() {
                return Ok(account.tokens.clone());
            }
        }
    }
    let tokens = refresh_tokens(client, account).await?;
    let now = chrono::Utc::now().to_rfc3339();
    vault::update_tokens(&account.id, &tokens, &now)?;
    Ok(tokens)
}

fn remaining_percent(window: &Value) -> Option<f64> {
    let used = window.get("used_percent").and_then(|v| v.as_f64())?;
    Some((100.0 - used).clamp(0.0, 100.0))
}

/// `reset_at` is Unix seconds; the vault keeps Apple reference dates.
fn reset_ref(window: &Value) -> Option<f64> {
    let unix = window.get("reset_at").and_then(|v| v.as_f64())?;
    Some(unix - APPLE_REF_UNIX_OFFSET)
}

fn window_minutes(window: &Value) -> Option<f64> {
    window
        .get("limit_window_seconds")
        .and_then(|v| v.as_f64())
        .map(|s| s / 60.0)
}

#[derive(Clone, Debug, PartialEq)]
pub struct LiveQuotaReading {
    pub quota: Quota,
    /// Apple reference seconds, converted from management `observed_at`.
    pub observed_at: f64,
}

/// Parse passive quota headers saved by the gateway. The exact reserve check
/// uses `100 - used_percent` with no epsilon or automatic margin.
pub fn parse_live_signals(
    signals: &HashMap<String, String>,
    observed_at: Option<&str>,
    fallback_unix: f64,
) -> Option<LiveQuotaReading> {
    if signals.is_empty() {
        return None;
    }
    let values: HashMap<String, String> = signals
        .iter()
        .map(|(key, value)| (key.to_ascii_lowercase(), value.trim().to_string()))
        .collect();
    let mut quota = Quota::default();
    quota.hourly_remaining_percent = remaining_signal(&values, "x-codex-primary-used-percent");
    quota.weekly_remaining_percent = remaining_signal(&values, "x-codex-secondary-used-percent");
    quota.hourly_window_minutes = number_signal(&values, "x-codex-primary-window-minutes");
    quota.weekly_window_minutes = number_signal(&values, "x-codex-secondary-window-minutes");
    quota.hourly_reset_at = reset_signal(
        &values,
        "x-codex-primary-reset-at",
        "x-codex-primary-reset-after-seconds",
        fallback_unix,
    );
    quota.weekly_reset_at = reset_signal(
        &values,
        "x-codex-secondary-reset-at",
        "x-codex-secondary-reset-after-seconds",
        fallback_unix,
    );
    quota.hourly_window_present = Some(quota.hourly_remaining_percent.is_some());
    quota.weekly_window_present = Some(quota.weekly_remaining_percent.is_some());
    if quota.hourly_remaining_percent.is_none() && quota.weekly_remaining_percent.is_none() {
        return None;
    }
    let observed_unix = observed_at
        .and_then(|raw| chrono::DateTime::parse_from_rfc3339(raw).ok())
        .map(|date| date.timestamp_millis() as f64 / 1000.0)
        .unwrap_or(fallback_unix);
    Some(LiveQuotaReading {
        quota,
        observed_at: observed_unix - APPLE_REF_UNIX_OFFSET,
    })
}

fn remaining_signal(values: &HashMap<String, String>, key: &str) -> Option<f64> {
    let used = values.get(key)?.parse::<f64>().ok()?;
    Some((100.0 - used).clamp(0.0, 100.0))
}

fn number_signal(values: &HashMap<String, String>, key: &str) -> Option<f64> {
    values.get(key)?.parse::<f64>().ok()
}

fn reset_signal(
    values: &HashMap<String, String>,
    at_key: &str,
    after_key: &str,
    now: f64,
) -> Option<f64> {
    if let Some(at) = number_signal(values, at_key).filter(|value| *value > 0.0) {
        return Some(at - APPLE_REF_UNIX_OFFSET);
    }
    number_signal(values, after_key)
        .filter(|seconds| *seconds >= 0.0)
        .map(|seconds| now + seconds - APPLE_REF_UNIX_OFFSET)
}

pub async fn fetch_usage(
    client: &Client,
    account: &Account,
    tokens: &Tokens,
) -> Result<(Quota, String), String> {
    let access = tokens.access_token.clone().ok_or("нет access_token")?;
    let mut request = client
        .get(USAGE_ENDPOINT)
        .header("Authorization", format!("Bearer {}", access))
        .header("User-Agent", USER_AGENT)
        .header("originator", ORIGINATOR);
    let account_id = account.account_id.clone().or(tokens.account_id.clone());
    if let Some(id) = account_id.filter(|v| !v.is_empty()) {
        request = request.header("ChatGPT-Account-Id", id);
    }
    let resp = request.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!(
            "usage {}: {}",
            status.as_u16(),
            text.chars().take(200).collect::<String>()
        ));
    }
    let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let mut quota = Quota::default();
    let rate = value.get("rate_limit");
    if let Some(primary) = rate.and_then(|r| r.get("primary_window")) {
        quota.hourly_window_present = Some(true);
        quota.hourly_remaining_percent = remaining_percent(primary);
        quota.hourly_reset_at = reset_ref(primary);
        quota.hourly_window_minutes = window_minutes(primary);
    } else {
        quota.hourly_window_present = Some(false);
        quota.hourly_remaining_percent = Some(100.0);
    }
    if let Some(secondary) = rate.and_then(|r| r.get("secondary_window")) {
        quota.weekly_window_present = Some(true);
        quota.weekly_remaining_percent = remaining_percent(secondary);
        quota.weekly_reset_at = reset_ref(secondary);
        quota.weekly_window_minutes = window_minutes(secondary);
    } else {
        quota.weekly_window_present = Some(false);
        quota.weekly_remaining_percent = Some(100.0);
    }
    Ok((quota, text))
}

pub async fn refresh_one(client: &Client, account: &Account) -> Result<(), String> {
    let mut tokens = ensure_fresh(client, account).await?;
    let mut usage = fetch_usage(client, account, &tokens).await;
    if matches!(&usage, Err(error) if error.starts_with("usage 401:")) {
        // Providers can revoke an access token before its JWT expiry. Retry
        // once with a freshly rotated token instead of leaving the reset
        // probe stuck until the next long quota interval.
        tokens = refresh_tokens(client, account).await?;
        vault::update_tokens(&account.id, &tokens, &chrono::Utc::now().to_rfc3339())?;
        usage = fetch_usage(client, account, &tokens).await;
    }
    match usage {
        Ok((quota, raw)) => {
            // Reset credits (5h-window refills) and model availability ride
            // along with the usage fetch.
            let mut extra = usage_credits(&raw);
            if let Some(models) = model_availability(&raw) {
                extra.insert("modelAvailability".to_string(), models);
            }
            if let Ok(resets) = fetch_reset_credits(client, account, &tokens).await {
                if let Some(available) = resets.available {
                    extra.insert("resetCreditsAvailable".to_string(), json!(available));
                }
                if let Some(expiry) = resets.next_expiry {
                    extra.insert(
                        "resetCreditsNextExpiry".to_string(),
                        json!(expiry - APPLE_REF_UNIX_OFFSET),
                    );
                }
            }
            vault::update_quota(&account.id, &quota, &raw, Value::Object(extra))?;

            // Sparkline sample. A history write failure must not fail the
            // quota refresh.
            crate::history::record(
                &account.id,
                "codex",
                quota.hourly_remaining_percent,
                quota.weekly_remaining_percent,
            );

            // Subscription dates refresh at most every 30 minutes (or when
            // missing), like the macOS app.
            let subscription_age = account
                .subscription_updated_at
                .map(|updated| now_ref() - updated)
                .unwrap_or(f64::INFINITY);
            if account.subscription_active_until.is_none() || subscription_age >= 1800.0 {
                if let Ok((plan, until)) = fetch_subscription(client, account, &tokens).await {
                    let _ =
                        vault::update_subscription(&account.id, plan.as_deref(), until.as_deref());
                }
            }
            Ok(())
        }
        Err(error) => {
            let _ = vault::set_quota_error(&account.id, &error);
            Err(error)
        }
    }
}

/// Credits from the same usage response, using the macOS CodexService schema.
/// Missing/malformed fields stay absent so a partial response cannot erase the
/// last known balance when `vault::update_quota` merges this extra metadata.
fn usage_credits(raw: &str) -> serde_json::Map<String, Value> {
    let mut extra = serde_json::Map::new();
    let value = serde_json::from_str::<Value>(raw).unwrap_or(Value::Null);
    if let Some(credits) = value.get("credits").and_then(Value::as_object) {
        if let Some(balance) = credits.get("balance").and_then(Value::as_str) {
            extra.insert("creditsBalance".to_string(), json!(balance));
        }
        if let Some(unlimited) = credits.get("unlimited").and_then(Value::as_bool) {
            extra.insert("unlimitedCredits".to_string(), json!(unlimited));
        }
        if let Some(has_credits) = credits.get("has_credits").and_then(Value::as_bool) {
            extra.insert("hasCredits".to_string(), json!(has_credits));
        }
    }
    extra
}

/// Model availability list from the usage response (`model_usage`).
fn model_availability(raw: &str) -> Option<Value> {
    let value: Value = serde_json::from_str(raw).ok()?;
    let usage = value.get("model_usage")?.as_object()?;
    let mut list: Vec<Value> = usage
        .iter()
        .filter_map(|(model, info)| {
            let info = info.as_object()?;
            Some(json!({
                "model": model,
                "available": info.get("available").and_then(|v| v.as_bool()).unwrap_or(false),
                "availableAt": info.get("available_at").cloned().unwrap_or(Value::Null),
                "creditsWouldEnable": info.get("credits_would_enable").and_then(|v| v.as_bool()).unwrap_or(false),
            }))
        })
        .collect();
    list.sort_by(|a, b| {
        a.get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .cmp(b.get("model").and_then(|v| v.as_str()).unwrap_or(""))
    });
    Some(Value::Array(list))
}

/// One banked reset credit. The id is sent back on redemption; only
/// spendable records (available/granted) are kept.
#[derive(Clone, Debug, PartialEq)]
struct ResetCreditRecord {
    id: String,
    status: String,
    expires_at: Option<f64>,
}

#[derive(Clone, Debug, Default)]
struct ResetCreditDetails {
    available: Option<i64>,
    next_expiry: Option<f64>,
    credits: Vec<ResetCreditRecord>,
}

/// 5h reset credits: how many are usable, when the nearest expires, and the
/// individual records used to redeem the soonest-expiring one.
async fn fetch_reset_credits(
    client: &Client,
    account: &Account,
    tokens: &Tokens,
) -> Result<ResetCreditDetails, String> {
    let access = tokens.access_token.clone().ok_or("нет access_token")?;
    let mut request = client
        .get(RESET_CREDITS_ENDPOINT)
        .header("Authorization", format!("Bearer {}", access))
        .header("User-Agent", USER_AGENT)
        .header("originator", ORIGINATOR)
        .header("Accept", "application/json");
    let account_id = account.account_id.clone().or(tokens.account_id.clone());
    if let Some(id) = account_id.filter(|v| !v.is_empty()) {
        request = request.header("ChatGPT-Account-Id", id);
    }
    let resp = request.send().await.map_err(|e| e.to_string())?;
    let text = resp.text().await.map_err(|e| e.to_string())?;
    let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    Ok(parse_reset_credits(&value))
}

fn parse_reset_credits(value: &Value) -> ResetCreditDetails {
    let nested = value.get("data");
    let available = value
        .get("available_count")
        .and_then(|v| v.as_i64())
        .or_else(|| value.get("availableCount").and_then(|v| v.as_i64()))
        .or_else(|| {
            nested
                .and_then(|d| d.get("available_count"))
                .and_then(|v| v.as_i64())
        })
        .or_else(|| {
            nested
                .and_then(|d| d.get("availableCount"))
                .and_then(|v| v.as_i64())
        });
    let records = value.get("credits").and_then(|v| v.as_array()).or_else(|| {
        nested
            .and_then(|d| d.get("credits"))
            .and_then(|v| v.as_array())
    });
    let mut credits = Vec::new();
    if let Some(records) = records {
        for record in records {
            let status = record
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_lowercase();
            if !status.is_empty() && status != "available" && status != "granted" {
                continue;
            }
            let id = record
                .get("id")
                .and_then(|v| v.as_str())
                .or_else(|| record.get("credit_id").and_then(|v| v.as_str()))
                .unwrap_or("");
            if id.is_empty() {
                continue;
            }
            credits.push(ResetCreditRecord {
                id: id.to_string(),
                status,
                expires_at: reset_credit_date(record),
            });
        }
    }
    let next_expiry = credits
        .iter()
        .filter_map(|credit| credit.expires_at)
        .min_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let resolved_available = available.or_else(|| records.map(|_| credits.len() as i64));
    ResetCreditDetails {
        available: resolved_available,
        next_expiry,
        credits,
    }
}

fn reset_credit_date(record: &Value) -> Option<f64> {
    for key in ["expires_at", "expiresAt", "expiry"] {
        let Some(value) = record.get(key) else {
            continue;
        };
        if let Some(raw) = value.as_str() {
            return parse_any_date(raw);
        }
        if let Some(number) = value.as_f64() {
            return Some(if number > 1_000_000_000_000.0 {
                number / 1000.0
            } else {
                number
            });
        }
    }
    None
}

/// The nearest-expiring redeemable credit, or `None` when the details are
/// unavailable. Credits without an expiry sort last.
fn soonest_reset_credit(credits: Vec<ResetCreditRecord>) -> Option<String> {
    credits
        .into_iter()
        .filter(|credit| credit.status.is_empty() || credit.status == "available")
        .min_by(|left, right| match (left.expires_at, right.expires_at) {
            (Some(a), Some(b)) => a.partial_cmp(&b).unwrap_or(std::cmp::Ordering::Equal),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => left.id.cmp(&right.id),
        })
        .map(|credit| credit.id)
}

/// `redeem_request_id` is a UUID v4; the backend uses it as the idempotency
/// key, so a retry cannot spend a second credit.
fn reset_request_id() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{:02x}", byte)).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

fn parse_reset_outcome(value: &Value) -> Option<&'static str> {
    let nested = value.get("data");
    let raw = value
        .get("outcome")
        .and_then(|v| v.as_str())
        .or_else(|| value.get("code").and_then(|v| v.as_str()))
        .or_else(|| {
            nested
                .and_then(|d| d.get("outcome"))
                .and_then(|v| v.as_str())
        })
        .or_else(|| nested.and_then(|d| d.get("code")).and_then(|v| v.as_str()))?;
    match raw {
        "reset" => Some("reset"),
        "nothing_to_reset" | "nothingToReset" => Some("nothing_to_reset"),
        "no_credit" | "noCredit" => Some("no_credit"),
        "already_redeemed" | "alreadyRedeemed" => Some("already_redeemed"),
        _ => None,
    }
}

/// Mark an account as being reset. Returns false when a redemption for the
/// same account is already in flight.
pub fn begin_reset(id: &str) -> bool {
    if let Ok(mut guard) = RESET_IN_FLIGHT
        .get_or_init(|| Mutex::new(HashSet::new()))
        .lock()
    {
        guard.insert(id.to_string())
    } else {
        false
    }
}

pub fn end_reset(id: &str) {
    if let Ok(mut guard) = RESET_IN_FLIGHT
        .get_or_init(|| Mutex::new(HashSet::new()))
        .lock()
    {
        guard.remove(id);
    }
}

/// Redeem one banked reset. The backend picks the credit when the detailed
/// list is unavailable; otherwise the nearest-expiring credit is used.
pub async fn consume_reset_credit(
    client: &Client,
    account: &Account,
) -> Result<&'static str, String> {
    let tokens = ensure_fresh(client, account).await?;
    let access = tokens.access_token.clone().ok_or("нет access_token")?;
    let credit_id = match fetch_reset_credits(client, account, &tokens).await {
        Ok(details) => soonest_reset_credit(details.credits),
        Err(_) => None,
    };
    let mut body = json!({ "redeem_request_id": reset_request_id() });
    if let Some(id) = credit_id {
        body["credit_id"] = json!(id);
    }
    let mut request = client
        .post(CONSUME_RESET_CREDIT_ENDPOINT)
        .header("Authorization", format!("Bearer {}", access))
        .header("User-Agent", USER_AGENT)
        .header("originator", ORIGINATOR)
        .header("Accept", "application/json")
        .json(&body);
    let account_id = account.account_id.clone().or(tokens.account_id.clone());
    if let Some(id) = account_id.filter(|v| !v.is_empty()) {
        request = request.header("ChatGPT-Account-Id", id);
    }
    let resp = request.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!(
            "reset {}: {}",
            status.as_u16(),
            text.chars().take(300).collect::<String>()
        ));
    }
    let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    parse_reset_outcome(&value).ok_or_else(|| {
        format!(
            "неизвестный ответ сброса: {}",
            text.chars().take(200).collect::<String>()
        )
    })
}

/// Subscription URL with the account id percent-encoded: the id is opaque and
/// may carry `+`, `&`, `=` (the header variant stays unencoded).
fn subscription_url(account_id: Option<&str>) -> String {
    const BASE: &str = "https://chatgpt.com/backend-api/subscriptions";
    match account_id.filter(|value| !value.is_empty()) {
        Some(id) => format!("{}?account_id={}", BASE, crate::claude::url_query(id)),
        None => BASE.to_string(),
    }
}

/// Subscription plan + end date (the backend is authoritative).
async fn fetch_subscription(
    client: &Client,
    account: &Account,
    tokens: &Tokens,
) -> Result<(Option<String>, Option<String>), String> {
    let access = tokens.access_token.clone().ok_or("нет access_token")?;
    let account_id = account.account_id.clone().or(tokens.account_id.clone());
    let url = subscription_url(account_id.as_deref());
    let mut request = client
        .get(url)
        .header("Authorization", format!("Bearer {}", access))
        .header("Accept", "application/json")
        .header("Referer", "https://chatgpt.com/")
        .header("User-Agent", WEB_USER_AGENT)
        .header("x-openai-target-path", "/backend-api/subscriptions")
        .header("x-openai-target-route", "/backend-api/subscriptions");
    if let Some(id) = account_id.filter(|v| !v.is_empty()) {
        request = request.header("ChatGPT-Account-Id", id);
    }
    let resp = request.send().await.map_err(|e| e.to_string())?;
    let text = resp.text().await.map_err(|e| e.to_string())?;
    let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let plan = value
        .get("subscription_plan")
        .and_then(|v| v.as_str())
        .or_else(|| value.get("plan_type").and_then(|v| v.as_str()))
        .map(String::from);
    let until = value
        .get("active_until")
        .and_then(|v| v.as_str())
        .or_else(|| value.get("expires_at").and_then(|v| v.as_str()))
        .map(String::from);
    Ok((plan, until))
}

fn parse_any_date(raw: &str) -> Option<f64> {
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(raw) {
        return Some(dt.timestamp() as f64);
    }
    if let Ok(number) = raw.parse::<f64>() {
        // Reset-credit timestamps arrive as Unix seconds or milliseconds.
        return Some(if number > 1_000_000_000_000.0 {
            number / 1000.0
        } else {
            number
        });
    }
    None
}

pub async fn refresh_all(client: &Client, only: Option<&str>) -> Vec<String> {
    let mut errors = Vec::new();
    for account in vault::accounts() {
        if let Some(id) = only {
            if account.id != id {
                continue;
            }
        }
        if let Err(error) = refresh_one(client, &account).await {
            errors.push(format!("{}: {}", account.display_name(), error));
        }
    }
    errors
}

/// Window affected by a block code: `hourly` or `weekly`.
pub fn block_window(code: &str) -> Option<&'static str> {
    match code {
        "hourly_exhausted" | "hourly_reserve" => Some("hourly"),
        "weekly_exhausted" | "weekly_reserve" => Some("weekly"),
        _ => None,
    }
}

/// A reset toast is due only when the account left the blocked state and this
/// account/window marker was not announced already.
pub fn should_notify_quota_reset(
    previous_blocked: bool,
    current_blocked: bool,
    already_notified: bool,
) -> bool {
    previous_blocked && !current_blocked && !already_notified
}

/// Stable per-window marker. The reset timestamp is authoritative; without one
/// the current hour is the fallback bucket so a broken payload cannot spam.
pub fn reset_notification_key(
    account_id: &str,
    window: &str,
    reset_at: Option<f64>,
    now: i64,
) -> String {
    match reset_at.filter(|value| value.is_finite()) {
        Some(reset) => format!("{}:{}:r{:.0}", account_id, window, reset),
        None => format!("{}:{}:t{}", account_id, window, now.div_euclid(3600)),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        block_window, parse_live_signals, parse_reset_credits, parse_reset_outcome,
        reset_notification_key, reset_request_id, should_notify_quota_reset, soonest_reset_credit,
        subscription_url, ResetCreditRecord,
    };
    use crate::vault::APPLE_REF_UNIX_OFFSET;
    use serde_json::json;
    use std::collections::HashMap;

    #[test]
    fn usage_credits_match_macos_and_keep_explicit_false_and_zero() {
        let credits = super::usage_credits(r#"{"credits":{"balance":"0","unlimited":false,"has_credits":false}}"#);
        assert_eq!(credits.get("creditsBalance"), Some(&json!("0")));
        assert_eq!(credits.get("unlimitedCredits"), Some(&json!(false)));
        assert_eq!(credits.get("hasCredits"), Some(&json!(false)));
        assert_eq!(super::usage_credits(r#"{"credits":{"balance":"12.50","unlimited":true}}"#).get("creditsBalance"), Some(&json!("12.50")));
        assert!(super::usage_credits(r#"{"credits":{"balance":12,"unlimited":"true","has_credits":null}}"#).is_empty());
        assert!(super::usage_credits(r#"{"rate_limit":{}}"#).is_empty());
        assert!(super::usage_credits("not json").is_empty());
    }

    #[test]
    fn reset_credits_keep_available_records_and_the_nearest_expiry() {
        let value = json!({
            "available_count": 2,
            "credits": [
                {
                    "id": "RateLimitResetCredit_b",
                    "status": "available",
                    "title": "Full reset (Weekly + 5 hr)",
                    "expires_at": "2026-08-20T10:00:00Z"
                },
                {
                    "id": "RateLimitResetCredit_a",
                    "status": "available",
                    "expires_at": "2026-08-10T10:00:00Z"
                },
                {
                    "id": "RateLimitResetCredit_used",
                    "status": "redeemed",
                    "expires_at": "2026-07-01T10:00:00Z"
                }
            ]
        });

        let details = parse_reset_credits(&value);

        assert_eq!(details.available, Some(2));
        assert_eq!(
            details
                .credits
                .iter()
                .map(|c| c.id.as_str())
                .collect::<Vec<_>>(),
            vec!["RateLimitResetCredit_b", "RateLimitResetCredit_a"]
        );
        let expected = chrono::DateTime::parse_from_rfc3339("2026-08-10T10:00:00Z")
            .unwrap()
            .timestamp() as f64;
        assert_eq!(details.next_expiry, Some(expected));
    }

    #[test]
    fn reset_credits_parse_the_nested_camel_case_shape_and_numeric_seconds() {
        let value = json!({
            "data": {
                "availableCount": 1,
                "credits": [
                    { "credit_id": "credit-1", "status": "available", "expires_at": 1_800_000_000 }
                ]
            }
        });

        let details = parse_reset_credits(&value);

        assert_eq!(details.available, Some(1));
        assert_eq!(details.credits.len(), 1);
        assert_eq!(details.credits[0].id, "credit-1");
        assert_eq!(details.next_expiry, Some(1_800_000_000.0));
    }

    #[test]
    fn reset_credits_fall_back_to_record_count_when_available_is_missing() {
        let value = json!({
            "credits": [
                { "id": "a", "status": "", "expires_at": "2026-08-10T10:00:00Z" },
                { "id": "b", "status": "granted" }
            ]
        });

        let details = parse_reset_credits(&value);

        assert_eq!(details.available, Some(2));
        assert_eq!(details.credits.len(), 2);
    }

    #[test]
    fn soonest_reset_credit_prefers_expiry_and_skips_spent_records() {
        let credits = vec![
            ResetCreditRecord {
                id: "later".to_string(),
                status: "available".to_string(),
                expires_at: Some(200.0),
            },
            ResetCreditRecord {
                id: "sooner".to_string(),
                status: "available".to_string(),
                expires_at: Some(100.0),
            },
            ResetCreditRecord {
                id: "no-expiry".to_string(),
                status: "available".to_string(),
                expires_at: None,
            },
            ResetCreditRecord {
                id: "spent".to_string(),
                status: "redeemed".to_string(),
                expires_at: Some(1.0),
            },
        ];

        assert_eq!(soonest_reset_credit(credits), Some("sooner".to_string()));
    }

    #[test]
    fn reset_outcome_accepts_both_naming_styles_and_nested_payloads() {
        assert_eq!(
            parse_reset_outcome(&json!({"outcome": "reset"})),
            Some("reset")
        );
        assert_eq!(
            parse_reset_outcome(&json!({"outcome": "nothing_to_reset"})),
            Some("nothing_to_reset")
        );
        assert_eq!(
            parse_reset_outcome(&json!({"code": "nothingToReset"})),
            Some("nothing_to_reset")
        );
        assert_eq!(
            parse_reset_outcome(&json!({"outcome": "no_credit"})),
            Some("no_credit")
        );
        assert_eq!(
            parse_reset_outcome(&json!({"data": {"code": "alreadyRedeemed"}})),
            Some("already_redeemed")
        );
        assert_eq!(parse_reset_outcome(&json!({"outcome": "mystery"})), None);
        assert_eq!(parse_reset_outcome(&json!({})), None);
    }

    #[test]
    fn reset_request_id_is_a_uuid_v4() {
        let id = reset_request_id();
        assert_eq!(id.len(), 36);
        let parts: Vec<&str> = id.split('-').collect();
        assert_eq!(
            parts.iter().map(|part| part.len()).collect::<Vec<_>>(),
            vec![8, 4, 4, 4, 12]
        );
        assert_eq!(&id[14..15], "4");
        assert!(matches!(&id[19..20], "8" | "9" | "a" | "b"));
    }

    #[test]
    fn subscription_url_percent_encodes_account_id() {
        assert_eq!(
            subscription_url(None),
            "https://chatgpt.com/backend-api/subscriptions"
        );
        assert_eq!(
            subscription_url(Some("")),
            "https://chatgpt.com/backend-api/subscriptions"
        );
        assert_eq!(
            subscription_url(Some("user-123")),
            "https://chatgpt.com/backend-api/subscriptions?account_id=user-123"
        );
        assert_eq!(
            subscription_url(Some("a+b&c=d/e")),
            "https://chatgpt.com/backend-api/subscriptions?account_id=a%2Bb%26c%3Dd%2Fe"
        );
    }

    #[test]
    fn reset_notification_fires_only_after_leaving_the_blocked_state() {
        assert!(should_notify_quota_reset(true, false, false));
        assert!(!should_notify_quota_reset(true, false, true));
        assert!(!should_notify_quota_reset(false, false, false));
        assert!(!should_notify_quota_reset(true, true, false));
    }

    #[test]
    fn reset_marker_is_stable_per_window_and_moves_with_the_reset() {
        let first = reset_notification_key("acc", "hourly", Some(1_700_000_000.4), 10);
        let same = reset_notification_key("acc", "hourly", Some(1_700_000_000.1), 99_999);
        let next = reset_notification_key("acc", "hourly", Some(1_700_003_600.0), 10);
        assert_eq!(first, same);
        assert_ne!(first, next);
        assert!(first.contains("acc:hourly:r"));
    }

    #[test]
    fn reset_marker_falls_back_to_an_hour_bucket_without_a_reset_time() {
        let same = reset_notification_key("acc", "quota", None, 7_200);
        assert_eq!(same, reset_notification_key("acc", "quota", None, 7_500));
        assert_ne!(same, reset_notification_key("acc", "quota", None, 10_800));
        assert!(same.ends_with(":t2"));
    }

    #[test]
    fn block_codes_map_to_their_quota_window() {
        assert_eq!(block_window("hourly_exhausted"), Some("hourly"));
        assert_eq!(block_window("hourly_reserve"), Some("hourly"));
        assert_eq!(block_window("weekly_exhausted"), Some("weekly"));
        assert_eq!(block_window("weekly_reserve"), Some("weekly"));
        assert_eq!(block_window("something_else"), None);
    }

    #[test]
    fn parses_live_codex_signals_and_exact_remaining_percent() {
        let signals = HashMap::from([
            ("X-Codex-Primary-Used-Percent".to_string(), "98".to_string()),
            (
                "X-Codex-Primary-Window-Minutes".to_string(),
                "300".to_string(),
            ),
            (
                "X-Codex-Primary-Reset-After-Seconds".to_string(),
                "120".to_string(),
            ),
            (
                "X-Codex-Secondary-Used-Percent".to_string(),
                "27.5".to_string(),
            ),
        ]);
        let now = 1_800_000_000.0;
        let reading = parse_live_signals(&signals, None, now).unwrap();
        assert_eq!(reading.quota.hourly_remaining_percent, Some(2.0));
        assert_eq!(reading.quota.weekly_remaining_percent, Some(72.5));
        assert_eq!(
            reading.quota.hourly_reset_at,
            Some(now + 120.0 - APPLE_REF_UNIX_OFFSET)
        );
        assert_eq!(reading.quota.hourly_window_minutes, Some(300.0));
    }

    #[test]
    fn ignores_live_signals_without_a_quota_window() {
        let signals = HashMap::from([("Retry-After".to_string(), "30".to_string())]);
        assert!(parse_live_signals(&signals, None, 1_800_000_000.0).is_none());
    }

    #[test]
    fn shared_quota_fixture_matches_both_platforms() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/quota-signals.json"
        ))
        .unwrap();
        let now = 1_800_000_000.0;
        for case in fixture["cases"].as_array().unwrap() {
            let mut signals = HashMap::new();
            for (key, value) in case["signals"].as_object().unwrap() {
                signals.insert(key.clone(), value.as_str().unwrap().to_string());
            }
            let reading = parse_live_signals(&signals, None, now);
            let expected = &case["expected"];
            if let Some(hourly) = expected["hourlyRemaining"].as_f64() {
                assert_eq!(
                    reading.as_ref().unwrap().quota.hourly_remaining_percent,
                    Some(hourly),
                    "{}",
                    case["name"]
                );
            }
            if let Some(weekly) = expected["weeklyRemaining"].as_f64() {
                assert_eq!(
                    reading.as_ref().unwrap().quota.weekly_remaining_percent,
                    Some(weekly),
                    "{}",
                    case["name"]
                );
            }
            if let Some(minutes) = expected["hourlyWindowMinutes"].as_f64() {
                assert_eq!(
                    reading.as_ref().unwrap().quota.hourly_window_minutes,
                    Some(minutes),
                    "{}",
                    case["name"]
                );
            }
        }
    }
}
