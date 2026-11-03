//! Melon Tools for Windows — Codex account pool, local API gateway, chips
//! bridge and the scheduler/instances tooling. Tauri 2 backend with the same
//! vault and gateway layout as the macOS app.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod account_import;
mod antigravity;
mod backup;
mod bridge;
mod catalog;
mod claude;
mod codex_models;
mod codex_route;
mod device_login;
mod dpapi;
mod engine;
mod gateway;
mod history;
mod instances;
mod live_quota;
mod paths;
mod provider_import;
mod providers;
mod proxy;
mod quota;
mod routing;
mod scheduler;
mod schema;
mod settings;
mod updater;
mod vault;

use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{Emitter, Manager, State};
use tauri_plugin_notification::NotificationExt;

pub struct AppState {
    pub gw: gateway::Gateway,
    pub bridge: bridge::BridgeState,
    pub settings: Mutex<settings::Settings>,
    /// Engine watchdog bookkeeping.
    pub watchdog: Mutex<Watchdog>,
    /// Last validated `update_check` result. `update_apply` uses only this
    /// copy and never trusts renderer-supplied URL/digest.
    pub update: Mutex<Option<updater::UpdateInfo>>,
    /// Cached status-island payload. The renderer polls it every few seconds;
    /// without this each poll re-reads the vault and parses the full scheduler
    /// history.
    pub island: Mutex<Option<(Instant, Value)>>,
}

/// Keeps the local engine alive: after we started (or adopted) the gateway,
/// two consecutive failed health probes trigger a bounded restart — unless
/// the user stopped it explicitly.
#[derive(Default, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Watchdog {
    pub supervised: bool,
    pub user_stopped: bool,
    #[serde(skip)]
    pub misses: u32,
    /// Last watchdog health probe; used to stop the 1.5 s quota loop while an
    /// adopted engine is down.
    #[serde(skip)]
    pub health_ok: bool,
    pub restarts: u32,
    pub last_restart: Option<String>,
    /// One-shot guard: a long-running log is rotated by a restart once per
    /// session, so a rotation that cannot shrink the file (adopted engine that
    /// keeps its handle) does not restart the gateway on every health tick.
    #[serde(skip)]
    pub log_rotated: bool,
}

impl AppState {
    fn settings(&self) -> settings::Settings {
        self.settings.lock().map(|s| s.clone()).unwrap_or_default()
    }
}

#[cfg(windows)]
fn hidden_command(_command: &mut std::process::Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        _command.creation_flags(0x0800_0000);
    }
}

// MARK: - App info / settings

#[tauri::command]
fn app_info() -> Value {
    json!({
        "name": "Melon Tools",
        "version": env!("CARGO_PKG_VERSION"),
        "platform": std::env::consts::OS,
        "dataDir": paths::appdata_dir().to_string_lossy(),
        "codexHome": paths::codex_home().to_string_lossy(),
        "enginePath": engine::engine_path().to_string_lossy(),
        "schedulerPath": scheduler::path().to_string_lossy(),
    })
}

#[tauri::command]
async fn settings_get(state: State<'_, AppState>) -> Result<Value, String> {
    settings_view(&state.settings())
}

/// Renderer-facing settings. The management secret is app-internal (the engine
/// config and management calls need the plaintext value) and must not cross the
/// IPC boundary: it is redacted, the other fields pass through unchanged.
fn settings_view(settings: &settings::Settings) -> Result<Value, String> {
    let mut value = serde_json::to_value(settings).map_err(|e| e.to_string())?;
    if let Some(object) = value.as_object_mut() {
        object.insert("managementSecret".to_string(), json!(""));
        object.insert(
            "schemaError".to_string(),
            json!(settings.schema_error.clone().or_else(schema::error)),
        );
    }
    Ok(value)
}

#[tauri::command]
async fn settings_set(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    settings: settings::Settings,
) -> Result<Value, String> {
    let old = state.settings();
    let was_running = gateway::health(old.port, &old.api_key).await;
    let mut merged = settings;
    if !(1024..=65535).contains(&merged.port) {
        return Err("порт должен быть в диапазоне 1024–65535".to_string());
    }
    if !(60..=86_400).contains(&merged.quota_interval) {
        return Err("интервал квот: от 60 до 86400 секунд".to_string());
    }
    if merged.lang != "ru" && merged.lang != "en" {
        return Err("неизвестный язык".to_string());
    }
    if merged.api_key.trim().is_empty() {
        merged.api_key = state.settings().api_key;
    }
    // The management secret is app-managed: a settings payload from an older
    // UI must not wipe the persisted value (a fresh one would invalidate every
    // management call until the engine reloads the config).
    if merged.management_secret.trim().is_empty() {
        merged.management_secret = state.settings().management_secret;
    }
    // Reset-notification markers are app-managed: an older UI payload without
    // them must not cause the same window to be announced again.
    if merged.quota_reset_notified.is_empty() {
        merged.quota_reset_notified = state.settings().quota_reset_notified;
    }
    settings::carry_provider_models(&mut merged, &old);
    settings::save(&merged)?;
    if let Ok(mut guard) = state.island.lock() {
        *guard = None;
    }
    proxy::configure(&merged);
    if let Ok(mut guard) = state.settings.lock() {
        *guard = merged.clone();
    }
    bridge::invalidate_providers(&state.bridge);
    if was_running && old.port == merged.port {
        let _ = gateway::write_config(&merged);
    }
    if old.lang != merged.lang {
        let _ = refresh_tray_menu(&app, &merged.lang);
    }
    set_island_visible(&app, merged.island_visible);
    if was_running && old.port != merged.port {
        let _ = stop_gateway(state.inner()).await;
        let _ = start_gateway(state.inner()).await;
    }
    settings_view(&merged)
}

// MARK: - Gateway

#[tauri::command]
async fn gateway_status(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let running = gateway::health(settings.port, &settings.api_key).await;
    Ok(json!({
        "running": running,
        "port": settings.port,
        "requestsLastMinute": gateway::requests_last_minute(),
        "liveQuotaTickMs": live_quota::last_tick_ms(),
        "schemaError": schema::error(),
        "sidecarFound": gateway::resolve_sidecar().is_some(),
        "dataDir": paths::appdata_dir().to_string_lossy(),
        "logPath": paths::log_path().to_string_lossy(),
        "watchdog": state
            .watchdog
            .lock()
            .map(|w| w.clone())
            .unwrap_or_default(),
    }))
}

#[tauri::command]
async fn support_bundle(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let running = gateway::health(settings.port, &settings.api_key).await;
    let accounts = vault::list_views();
    let blocked = accounts
        .iter()
        .filter(|account| {
            account
                .get("blocked")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .count();
    let quota_errors = accounts
        .iter()
        .filter(|account| {
            account
                .get("quotaError")
                .map(|v| !v.is_null())
                .unwrap_or(false)
        })
        .count();
    let scheduler = scheduler::summary();
    let log = paths::log_path();
    let config = paths::config_path();
    let watchdog = state.watchdog.lock().map(|w| w.clone()).unwrap_or_default();
    Ok(json!({
        "generatedAt": chrono::Utc::now().to_rfc3339(),
        "app": {
            "version": env!("CARGO_PKG_VERSION"),
            "platform": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
        },
        "gateway": {
            "running": running,
            "port": settings.port,
            "requestsLastMinute": gateway::requests_last_minute(),
            "liveQuotaTickMs": live_quota::last_tick_ms(),
            "watchdog": watchdog,
            "logBytes": std::fs::metadata(&log).map(|m| m.len()).unwrap_or(0),
            "configBytes": std::fs::metadata(&config).map(|m| m.len()).unwrap_or(0),
        },
        "settings": {
            "lang": settings.lang,
            "quotaInterval": settings.quota_interval,
            "routingStrategy": settings.routing_strategy,
            "notifications": settings.notifications,
            "schemaVersion": settings.schema_version,
        },
        "accounts": {
            "count": accounts.len(),
            "blocked": blocked,
            "quotaErrors": quota_errors,
        },
        "scheduler": {
            "taskCount": scheduler.get("taskCount").cloned().unwrap_or(json!(0)),
            "historyCount": scheduler.get("historyCount").cloned().unwrap_or(json!(0)),
            "enabledCount": scheduler.get("enabledCount").cloned().unwrap_or(json!(0)),
        },
        "paths": {
            "dataDir": paths::appdata_dir().to_string_lossy(),
            "codexHome": paths::codex_home().to_string_lossy(),
            "enginePath": engine::engine_path().to_string_lossy(),
            "schedulerPath": scheduler::path().to_string_lossy(),
        },
        "schemaError": schema::error(),
    }))
}

async fn start_gateway(state: &AppState) -> Result<String, String> {
    let settings = state.settings();
    let result = gateway::start(&state.gw, &settings).await?;
    // Generate the catalog before pointing Codex at it; a dangling
    // model_catalog_json can stop the Codex app from starting.
    if let Ok(client) = quota::local_client() {
        let _ = codex_route::sync_catalog(&client, settings.port, &settings.api_key).await;
    }
    if std::path::Path::new(&codex_route::catalog_path()).exists() {
        let _ = codex_route::apply(settings.port, &settings.api_key);
    }
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.supervised = true;
        guard.user_stopped = false;
        guard.misses = 0;
        guard.health_ok = true;
        // A manual start resets the restart budget: the user asked for it.
        guard.restarts = 0;
    }
    Ok(result)
}

async fn stop_gateway(state: &AppState) -> Result<String, String> {
    let result = gateway::stop(&state.gw)?;
    let _ = codex_route::remove();
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.user_stopped = true;
        guard.supervised = false;
        guard.health_ok = false;
    }
    Ok(result)
}

#[tauri::command]
async fn gateway_start(state: State<'_, AppState>) -> Result<String, String> {
    start_gateway(state.inner()).await
}

#[tauri::command]
async fn gateway_stop(state: State<'_, AppState>) -> Result<String, String> {
    stop_gateway(state.inner()).await
}

/// Rewrites config.yaml + gateway auth files from the vault.
#[tauri::command]
async fn gateway_sync(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    gateway::write_config(&settings)?;
    let written = gateway::sync_accounts(&settings)?;
    Ok(json!({ "syncedAccounts": written }))
}

#[tauri::command]
async fn gateway_check(state: State<'_, AppState>) -> Result<String, String> {
    let settings = state.settings();
    gateway::check_api(settings.port, &settings.api_key).await
}

#[tauri::command]
async fn gateway_recent_calls(limit: Option<usize>) -> Result<Value, String> {
    Ok(gateway::recent_calls(limit.unwrap_or(10)))
}

#[tauri::command]
async fn gateway_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    gateway::models(settings.port, &settings.api_key).await
}

// MARK: - Vault + quotas

#[tauri::command]
async fn vault_list() -> Result<Vec<Value>, String> {
    Ok(vault::list_views())
}

/// Last quota reading before a refresh, used to detect a crossing and a
/// recovered block.
type PreviousQuota = HashMap<String, PreviousAccount>;

#[derive(Clone)]
struct PreviousAccount {
    hourly: Option<f64>,
    weekly: Option<f64>,
    blocked: bool,
    block_code: Option<String>,
}

fn quota_snapshot() -> PreviousQuota {
    vault::accounts()
        .into_iter()
        .filter_map(|account| {
            let quota = account.quota.clone()?;
            let block_code = account.block_info().and_then(|info| {
                info.get("code")
                    .and_then(|code| code.as_str())
                    .map(String::from)
            });
            let id = account.id.clone();
            Some((
                id,
                PreviousAccount {
                    hourly: quota.hourly_remaining_percent,
                    weekly: quota.weekly_remaining_percent,
                    blocked: account.is_blocked(),
                    block_code,
                },
            ))
        })
        .collect()
}

#[tauri::command]
async fn quota_refresh(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    id: Option<String>,
) -> Result<Value, String> {
    let client = quota::client()?;
    let previous = quota_snapshot();
    let errors = quota::refresh_all(&client, id.as_deref()).await;
    let settings = state.settings();
    // Reconcile recovered sticky pauses before the UI and toasts read the
    // account state; otherwise the block lingers until the next live tick.
    live_quota::tick(&settings).await;
    let synced = if gateway::health(settings.port, &settings.api_key).await {
        gateway::sync_accounts(&settings).unwrap_or(0)
    } else {
        0
    };
    check_low_quota(&app, &state, &previous);
    check_quota_reset(&app, &state, &previous);
    Ok(json!({
        "accounts": vault::list_views(),
        "errors": errors,
        "syncedAccounts": synced,
    }))
}

/// Read-only quota history for the sparkline strips.
#[tauri::command]
fn quota_history() -> Vec<Value> {
    history::ipc_samples()
}

/// Redeem one banked Codex reset credit and refresh that account immediately.
/// The UI confirms before calling this command; `redeem_request_id` makes the
/// backend call idempotent, and the in-flight guard blocks double clicks.
#[tauri::command]
async fn reset_activate(state: State<'_, AppState>, id: String) -> Result<Value, String> {
    let account = vault::accounts()
        .into_iter()
        .find(|account| account.id == id)
        .ok_or_else(|| "аккаунт не найден".to_string())?;
    let available = vault::list_views()
        .into_iter()
        .find(|view| view.get("id").and_then(|value| value.as_str()) == Some(id.as_str()))
        .and_then(|view| {
            view.get("resetCreditsAvailable")
                .and_then(|value| value.as_i64())
        })
        .unwrap_or(0);
    if available <= 0 {
        return Err("no_credit".to_string());
    }
    let client = quota::client()?;
    if !quota::begin_reset(&id) {
        return Err("reset_in_progress".to_string());
    }
    let outcome = match quota::consume_reset_credit(&client, &account).await {
        Ok(outcome) => outcome,
        Err(error) => {
            quota::end_reset(&id);
            return Err(error);
        }
    };
    // Keep the card truthful even if the follow-up quota fetch fails: a
    // successful redemption always spends one credit.
    if outcome == "reset" {
        let remaining = (available - 1).max(0);
        let _ = vault::set_account_field(&id, move |item| {
            if !item
                .get("quota")
                .map(|value| value.is_object())
                .unwrap_or(false)
            {
                item["quota"] = json!({});
            }
            item["quota"]["resetCreditsAvailable"] = json!(remaining);
        });
    }
    let errors = quota::refresh_all(&client, Some(&id)).await;
    quota::end_reset(&id);
    let settings = state.settings();
    live_quota::tick(&settings).await;
    let synced = if gateway::health(settings.port, &settings.api_key).await {
        gateway::sync_accounts(&settings).unwrap_or(0)
    } else {
        0
    };
    Ok(json!({
        "accounts": vault::list_views(),
        "outcome": outcome,
        "errors": errors,
        "syncedAccounts": synced,
    }))
}

/// Toast when a refreshed window crosses below its account reserve (10 % when
/// the reserve is unset). `history::claim_notification` persists the reset
/// window id, so each window notifies at most once across restarts.
fn check_low_quota(app: &tauri::AppHandle, state: &AppState, previous: &PreviousQuota) {
    let settings = state.settings();
    if !settings.notifications || !settings.notify_low_quota {
        return;
    }
    let now = chrono::Utc::now().timestamp();
    let english = settings.lang == "en";
    for account in vault::accounts() {
        let Some(quota) = account.quota.clone() else {
            continue;
        };
        let before = previous.get(&account.id);
        let checks = [
            (
                "5h",
                quota.hourly_remaining_percent,
                quota.hourly_reset_at,
                account.hourly_reserve_percent,
                before.and_then(|value| value.hourly),
                3600i64,
                if english {
                    "5-hour window"
                } else {
                    "5-часовое окно"
                },
            ),
            (
                "week",
                quota.weekly_remaining_percent,
                quota.weekly_reset_at,
                account.weekly_reserve_percent,
                before.and_then(|value| value.weekly),
                21600i64,
                if english {
                    "weekly window"
                } else {
                    "недельное окно"
                },
            ),
        ];
        for (kind, remaining, reset_at, reserve, before_value, cooldown, label) in checks {
            let Some(remaining) = remaining else {
                continue;
            };
            let threshold = reserve
                .filter(|value| *value > 0)
                .map(|value| value as f64)
                .unwrap_or(10.0);
            let key = format!("{}:{}", account.id, kind);
            let claimed = history::claim_notification(
                &key,
                before_value,
                Some(remaining),
                threshold,
                reset_at,
                now,
                cooldown,
            )
            .unwrap_or(false);
            if !claimed {
                continue;
            }
            let body = if english {
                format!(
                    "{}: {}% left ≤ {}% threshold ({})",
                    account.display_name(),
                    remaining.round() as i64,
                    threshold.round() as i64,
                    label
                )
            } else {
                format!(
                    "{}: осталось {}% ≤ порога {}% ({})",
                    account.display_name(),
                    remaining.round() as i64,
                    threshold.round() as i64,
                    label
                )
            };
            let _ = app
                .notification()
                .builder()
                .title(if english {
                    "Melon Tools · low quota"
                } else {
                    "Melon Tools · низкая квота"
                })
                .body(body)
                .show();
        }
    }
}

/// One toast per account/window when a refresh turns a blocked account into a
/// usable one. The marker is stored in settings, so restarts cannot repeat it.
fn check_quota_reset(app: &tauri::AppHandle, state: &AppState, previous: &PreviousQuota) {
    let settings = state.settings();
    if !settings.notifications || !settings.notify_quota_reset {
        return;
    }
    let english = settings.lang == "en";
    let now = chrono::Utc::now().timestamp();
    let mut markers = settings.quota_reset_notified.clone();
    let mut changed = false;
    for account in vault::accounts() {
        let Some(before) = previous.get(&account.id) else {
            continue;
        };
        let Some(window) = before.block_code.as_deref().and_then(quota::block_window) else {
            continue;
        };
        let reset_at = match window {
            "hourly" => account
                .quota
                .as_ref()
                .and_then(|quota| quota.hourly_reset_at),
            "weekly" => account
                .quota
                .as_ref()
                .and_then(|quota| quota.weekly_reset_at),
            _ => None,
        }
        .map(|value| value + vault::APPLE_REF_UNIX_OFFSET);
        let key = quota::reset_notification_key(&account.id, window, reset_at, now);
        let notified = markers.iter().any(|marker| marker == &key);
        if !quota::should_notify_quota_reset(before.blocked, account.is_blocked(), notified) {
            continue;
        }
        markers.push(key);
        changed = true;
        let label = match (english, window) {
            (true, "hourly") => "5-hour window",
            (true, "weekly") => "weekly window",
            (false, "hourly") => "5-часовое окно",
            (false, "weekly") => "недельное окно",
            (true, _) => "quota",
            (false, _) => "квота",
        };
        let body = if english {
            format!("{}: {} is available again", account.display_name(), label)
        } else {
            format!("{}: {} снова доступна", account.display_name(), label)
        };
        let _ = app
            .notification()
            .builder()
            .title(if english {
                "Melon Tools · quota reset"
            } else {
                "Melon Tools · сброс квоты"
            })
            .body(body)
            .show();
    }
    if changed {
        if markers.len() > 200 {
            let excess = markers.len() - 200;
            markers.drain(0..excess);
        }
        if let Ok(mut guard) = state.settings.lock() {
            guard.quota_reset_notified = markers;
            let _ = settings::save(&guard);
        }
    }
}

#[tauri::command]
async fn switch_account(state: State<'_, AppState>, id: String) -> Result<Value, String> {
    let account = vault::accounts()
        .into_iter()
        .find(|a| a.id == id)
        .ok_or_else(|| "аккаунт не найден".to_string())?;
    let path = vault::write_codex_auth(&account)?;
    let mut raw = vault::load_raw();
    raw["currentAccountId"] = json!(id);
    vault::save_raw(&raw)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(json!({ "authPath": path.to_string_lossy() }))
}

#[tauri::command]
async fn import_current_auth(state: State<'_, AppState>) -> Result<Value, String> {
    let tokens = vault::read_codex_auth_tokens()
        .ok_or_else(|| "не нашёл %USERPROFILE%\\.codex\\auth.json — войдите в Codex".to_string())?;
    let result = vault::upsert_from_tokens(&tokens)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(json!({ "result": result, "accounts": vault::list_views() }))
}

#[tauri::command]
async fn import_json_accounts(
    state: State<'_, AppState>,
    content: String,
) -> Result<Value, String> {
    let result = account_import::import_json(&content)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(json!({
        "result": result,
        "accounts": vault::list_views(),
    }))
}

#[tauri::command]
async fn account_refresh_tokens(id: String) -> Result<Vec<Value>, String> {
    let account = vault::accounts()
        .into_iter()
        .find(|a| a.id == id)
        .ok_or_else(|| "аккаунт не найден".to_string())?;
    let client = quota::client()?;
    let tokens = quota::refresh_tokens(&client, &account).await?;
    vault::update_tokens(&id, &tokens, &chrono::Utc::now().to_rfc3339())?;
    Ok(vault::list_views())
}

#[tauri::command]
async fn save_reserves(
    state: State<'_, AppState>,
    id: String,
    hourly: Option<i64>,
    weekly: Option<i64>,
) -> Result<Vec<Value>, String> {
    vault::set_account_field(&id, move |item| {
        item["hourlyReservePercent"] = json!(hourly);
        item["weeklyReservePercent"] = json!(weekly);
    })?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(vault::list_views())
}

#[tauri::command]
async fn delete_account(state: State<'_, AppState>, id: String) -> Result<Vec<Value>, String> {
    vault::delete_account(&id)?;
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    Ok(vault::list_views())
}

// MARK: - Device login (add an account)

#[tauri::command]
async fn device_login_start() -> Result<Value, String> {
    let client = quota::client()?;
    device_login::start(&client).await
}

#[tauri::command]
async fn device_login_poll(
    state: State<'_, AppState>,
    device_auth_id: String,
    user_code: String,
) -> Result<Value, String> {
    let client = quota::client()?;
    match device_login::poll(&client, &device_auth_id, &user_code).await? {
        Some(tokens) => {
            let result = vault::upsert_from_tokens(&tokens)?;
            let settings = state.settings();
            if gateway::health(settings.port, &settings.api_key).await {
                let _ = gateway::sync_accounts(&settings);
            }
            Ok(json!({ "done": true, "result": result, "accounts": vault::list_views() }))
        }
        None => Ok(json!({ "done": false })),
    }
}

// MARK: - Routing

#[tauri::command]
async fn routing_state(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let accounts = vault::accounts();
    let (ordered, blocked) = routing::resolve(
        &accounts,
        &settings.routing_strategy,
        &settings.priority_order,
    );
    Ok(json!({
        "strategy": settings.routing_strategy,
        "strategies": routing::STRATEGIES,
        "priorityOrder": settings.priority_order,
        "orderedIds": ordered,
        "blockedIds": blocked,
    }))
}

#[tauri::command]
async fn set_routing_strategy(
    state: State<'_, AppState>,
    strategy: String,
) -> Result<Value, String> {
    if !routing::STRATEGIES.contains(&strategy.as_str()) {
        return Err(format!("неизвестная стратегия: {}", strategy));
    }
    mutate_settings(&state, |s| s.routing_strategy = strategy)?;
    resync(&state).await
}

#[tauri::command]
async fn move_priority(state: State<'_, AppState>, id: String, up: bool) -> Result<Value, String> {
    mutate_settings(&state, |s| {
        let mut order = s.priority_order.clone();
        if order.is_empty() {
            order = vault::accounts().iter().map(|a| a.id.clone()).collect();
        }
        if let Some(index) = order.iter().position(|value| value == &id) {
            let target = if up {
                index.checked_sub(1)
            } else if index + 1 < order.len() {
                Some(index + 1)
            } else {
                None
            };
            if let Some(target) = target {
                order.swap(index, target);
            }
        }
        s.priority_order = order;
    })?;
    mutate_settings(&state, |s| s.routing_strategy = "custom".to_string())?;
    resync(&state).await
}

#[tauri::command]
async fn reset_priority(state: State<'_, AppState>) -> Result<Value, String> {
    mutate_settings(&state, |s| {
        s.priority_order = vault::accounts().iter().map(|a| a.id.clone()).collect();
    })?;
    resync(&state).await
}

#[tauri::command]
async fn set_account_role(
    state: State<'_, AppState>,
    id: String,
    preferred: bool,
    backup: bool,
) -> Result<Value, String> {
    vault::set_account_field(&id, move |item| {
        item["preferredFirst"] = json!(preferred);
        item["isBackup"] = json!(backup);
    })?;
    resync(&state).await
}

fn mutate_settings(
    state: &State<'_, AppState>,
    mutate: impl FnOnce(&mut settings::Settings),
) -> Result<(), String> {
    let mut guard = state
        .settings
        .lock()
        .map_err(|_| "settings lock".to_string())?;
    mutate(&mut guard);
    settings::save(&guard)
}

async fn resync(state: &State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(&settings);
    }
    let accounts = vault::accounts();
    let (ordered, blocked) = routing::resolve(
        &accounts,
        &settings.routing_strategy,
        &settings.priority_order,
    );
    Ok(json!({
        "strategy": settings.routing_strategy,
        "priorityOrder": settings.priority_order,
        "orderedIds": ordered,
        "blockedIds": blocked,
        "accounts": vault::list_views(),
    }))
}

// MARK: - Codex route + chips bridge

#[tauri::command]
async fn codex_route_status() -> Result<Value, String> {
    Ok(codex_route::status())
}

#[tauri::command]
async fn catalog_sync(state: State<'_, AppState>) -> Result<usize, String> {
    let settings = state.settings();
    let client = quota::local_client().map_err(|e| e.to_string())?;
    codex_route::sync_catalog(&client, settings.port, &settings.api_key).await
}

#[tauri::command]
async fn codex_route_apply(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let custom = if let Ok(client) = quota::local_client() {
        codex_route::sync_catalog(&client, settings.port, &settings.api_key).await?
    } else {
        0
    };
    codex_route::apply(settings.port, &settings.api_key)?;
    Ok(json!({ "route": codex_route::status(), "catalogCustom": custom }))
}

#[tauri::command]
async fn codex_route_remove() -> Result<Value, String> {
    codex_route::remove()?;
    Ok(codex_route::status())
}

// MARK: - Codex desktop app

#[tauri::command]
async fn codex_app_status(state: State<'_, AppState>) -> Result<Value, String> {
    Ok(bridge::codex_app_status(&state.settings()))
}

#[tauri::command]
async fn codex_app_set_path(state: State<'_, AppState>, path: String) -> Result<Value, String> {
    let path = path.trim().to_string();
    if !bridge::valid_codex_exe(&path) {
        return Err("codex_path_invalid".to_string());
    }
    mutate_settings(&state, |settings| {
        settings.codex_exe_path = path.clone();
    })?;
    Ok(bridge::codex_app_status(&state.settings()))
}

#[tauri::command]
async fn codex_app_forget_path(state: State<'_, AppState>) -> Result<Value, String> {
    mutate_settings(&state, |settings| settings.codex_exe_path.clear())?;
    Ok(bridge::codex_app_status(&state.settings()))
}

/// One click from the API page: make sure the gateway is running, point Codex
/// at it, then reopen the desktop app with the chips debug port.
#[tauri::command]
async fn codex_app_open(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    if !gateway::health(settings.port, &settings.api_key).await {
        start_gateway(state.inner())
            .await
            .map_err(|_| "service_failed".to_string())?;
    }
    let settings = state.settings();
    if let Ok(client) = quota::local_client() {
        let _ = codex_route::sync_catalog(&client, settings.port, &settings.api_key).await;
    }
    codex_route::apply(settings.port, &settings.api_key)
        .map_err(|_| "codex_route_failed".to_string())?;
    let mut result = bridge::launch_codex_with_debug_port(&settings).await?;
    if let Some(object) = result.as_object_mut() {
        object.insert("route".to_string(), codex_route::status());
    }
    Ok(result)
}

// MARK: - Codex model pool (accounts × pool models)

/// Picker payload: the visible pool models with how many accounts select each
/// one. Read-only, so the UI can poll it without touching the vault.
fn pool_snapshot() -> Value {
    pool_snapshot_of(
        &codex_route::pool_models(),
        &vault::accounts(),
        &codex_route::visible_pool_slugs(),
    )
}

/// [`pool_snapshot`] against explicit inputs. The pool is read once, so the
/// per-model counts and the union cannot disagree. The union matches
/// `selected_pool_slugs` — same helper with the already-loaded pool.
fn pool_snapshot_of(
    models: &[codex_route::PoolModel],
    accounts: &[vault::Account],
    all: &HashSet<String>,
) -> Value {
    let mut selected_counts: HashMap<String, usize> = HashMap::new();
    for account in accounts {
        for slug in codex_route::effective_selected_models(account, all) {
            *selected_counts.entry(slug).or_insert(0) += 1;
        }
    }
    let account_count = accounts.len();
    let models: Vec<Value> = models
        .iter()
        .map(|model| {
            let mut entry = serde_json::to_value(model).unwrap_or_else(|_| json!({}));
            if let Some(object) = entry.as_object_mut() {
                object.insert(
                    "selectedCount".to_string(),
                    json!(selected_counts.get(&model.slug).copied().unwrap_or(0)),
                );
                object.insert("accountCount".to_string(), json!(account_count));
            }
            entry
        })
        .collect();
    json!({
        "models": models,
        "selectedCount": codex_route::selected_pool_slugs_in(accounts, all).len(),
        "accountCount": account_count,
    })
}

/// One account's new explicit selection after a pool-wide toggle, or `None`
/// when the toggle would leave it without any model. Sorted so repeated toggles
/// write the same vault payload.
fn pool_toggle_selection(
    current: &HashSet<String>,
    slug: &str,
    enabled: bool,
) -> Option<Vec<String>> {
    let mut next = current.clone();
    if enabled {
        next.insert(slug.to_string());
    } else {
        next.remove(slug);
    }
    if next.is_empty() {
        return None;
    }
    let mut list: Vec<String> = next.into_iter().collect();
    list.sort();
    Some(list)
}

/// New `selectedModels` for every account after a pool-wide toggle. All or
/// nothing: one account left empty rejects the whole change, naming the
/// accounts the UI must show in the error.
fn pool_toggle_plan(
    accounts: &[vault::Account],
    all: &HashSet<String>,
    slug: &str,
    enabled: bool,
) -> Result<HashMap<String, Vec<String>>, String> {
    let mut plan: HashMap<String, Vec<String>> = HashMap::new();
    let mut blocked: Vec<String> = Vec::new();
    for account in accounts {
        let current = codex_route::effective_selected_models(account, all);
        match pool_toggle_selection(&current, slug, enabled) {
            Some(selected) => {
                plan.insert(account.id.clone(), selected);
            }
            None => blocked.push(account.display_name()),
        }
    }
    if !blocked.is_empty() {
        return Err(format!(
            "нельзя изменить {}: {} останется без моделей",
            slug,
            blocked.join(", ")
        ));
    }
    Ok(plan)
}

/// Rewrites the gateway auth files when the engine is running. A stopped
/// engine picks the new selection up on its next start.
async fn sync_auth_accounts(settings: &settings::Settings) {
    if gateway::health(settings.port, &settings.api_key).await {
        let _ = gateway::sync_accounts(settings);
    }
}

/// Regenerates the Codex catalog and reports the failure instead of failing the
/// command: the selection is already saved and must not be rolled back.
async fn catalog_refresh_error(settings: &settings::Settings) -> Option<String> {
    let client = quota::local_client().ok()?;
    codex_route::sync_catalog(&client, settings.port, &settings.api_key)
        .await
        .err()
}

/// Visible pool models with selection counts for the models picker.
#[tauri::command]
fn codex_pool_models() -> Value {
    pool_snapshot()
}

/// Explicit refresh for the picker: fetch the official Codex client catalog,
/// merge it into the Codex cache, then return the refreshed pool.
#[tauri::command]
async fn codex_models_refresh() -> Result<Value, String> {
    codex_models::refresh_models().await?;
    Ok(pool_snapshot())
}

/// Saves one account's model allowlist, then re-syncs the engine and the
/// catalog. The selection is authoritative even when the catalog fails.
#[tauri::command]
async fn save_account_models(
    state: State<'_, AppState>,
    id: String,
    selected: Vec<String>,
) -> Result<Value, String> {
    vault::set_account_models(&id, selected)?;
    let settings = state.settings();
    sync_auth_accounts(&settings).await;
    let catalog_error = catalog_refresh_error(&settings).await;
    Ok(json!({
        "accounts": vault::list_views(),
        "pool": pool_snapshot(),
        "catalogError": catalog_error,
    }))
}

/// Enables or disables one pool model on every account at once.
#[tauri::command]
async fn set_pool_model(
    state: State<'_, AppState>,
    slug: String,
    enabled: bool,
) -> Result<Value, String> {
    let all = codex_route::visible_pool_slugs();
    if !all.contains(&slug) {
        return Err(format!("модель {} отсутствует в пуле", slug));
    }
    let accounts = vault::accounts();
    if accounts.is_empty() {
        return Ok(json!({
            "pool": pool_snapshot(),
            "accounts": vault::list_views(),
            "catalogError": Value::Null,
        }));
    }
    let plan = pool_toggle_plan(&accounts, &all, &slug, enabled)?;
    vault::set_all_account_selected_models(&plan)?;
    let settings = state.settings();
    sync_auth_accounts(&settings).await;
    let catalog_error = catalog_refresh_error(&settings).await;
    Ok(json!({
        "pool": pool_snapshot(),
        "accounts": vault::list_views(),
        "catalogError": catalog_error,
    }))
}

/// Applies the stored selection to the engine and the Codex catalog. Unlike
/// `save_account_models`, a catalog failure is a hard error here: the command
/// exists to make Codex match the vault.
#[tauri::command]
async fn apply_codex_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    sync_auth_accounts(&settings).await;
    let custom = if let Ok(client) = quota::local_client() {
        codex_route::sync_catalog(&client, settings.port, &settings.api_key).await?
    } else {
        0
    };
    Ok(json!({
        "pool": pool_snapshot(),
        "accounts": vault::list_views(),
        "custom": custom,
    }))
}

#[tauri::command]
async fn bridge_status(state: State<'_, AppState>) -> Result<Value, String> {
    let value = state
        .bridge
        .status
        .lock()
        .map(|v| v.clone())
        .unwrap_or_else(|_| json!({"attached": false}));
    Ok(value)
}

/// Restarts the Codex app with the CDP flags so the chips can attach.
#[tauri::command]
async fn bridge_launch_codex(state: State<'_, AppState>) -> Result<Value, String> {
    bridge::launch_codex_with_debug_port(&state.settings()).await
}

// MARK: - Scheduler

#[tauri::command]
async fn scheduler_list() -> Result<Value, String> {
    Ok(scheduler::view())
}

#[tauri::command]
async fn scheduler_summary() -> Result<Value, String> {
    Ok(scheduler::summary())
}

#[tauri::command]
async fn scheduler_tasks() -> Result<Value, String> {
    Ok(scheduler::tasks_view())
}

#[tauri::command]
async fn scheduler_history(page: Option<u32>, limit: Option<u32>) -> Result<Value, String> {
    Ok(scheduler::history_page(
        page.unwrap_or(1),
        limit.unwrap_or(50),
    ))
}

#[tauri::command]
async fn scheduler_result(id: String) -> Result<Value, String> {
    scheduler::result(&id)
}

#[tauri::command]
async fn scheduler_save(task: scheduler::TaskInput) -> Result<Value, String> {
    scheduler::upsert(task)
}

#[tauri::command]
async fn scheduler_delete(id: String) -> Result<Value, String> {
    scheduler::delete(&id)
}

#[tauri::command]
async fn scheduler_run_now(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    id: String,
) -> Result<Value, String> {
    let settings = state.settings();
    scheduler::run_now(&settings, &id, &app).await
}

/// Model ids served by the running gateway, grouped by id prefix. The picker
/// stores the exact id, so an unavailable gateway is a hard error the UI shows.
#[tauri::command]
async fn scheduler_cancel() -> Result<Value, String> {
    Ok(scheduler::cancel())
}

// MARK: - Backup

#[tauri::command]
async fn backup_export(password: String) -> Result<Value, String> {
    backup::export(&password)
}

#[tauri::command]
async fn backup_import(
    state: State<'_, AppState>,
    content: String,
    password: String,
) -> Result<Value, String> {
    let result = backup::import(&content, &password)?;
    // The restored settings.json may use another port/key. The running app
    // must not keep the pre-restore snapshot in memory.
    let restored = settings::load();
    if let Ok(mut guard) = state.settings.lock() {
        *guard = restored;
    }
    Ok(result)
}

#[tauri::command]
async fn backup_last() -> Result<Value, String> {
    Ok(serde_json::json!({ "createdAt": backup::last_backup_at() }))
}

#[tauri::command]
async fn scheduler_queue() -> Result<Value, String> {
    Ok(scheduler::queue_snapshot())
}

#[tauri::command]
async fn scheduler_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    scheduler::models(settings.port, &settings.api_key).await
}

// MARK: - Instances

#[tauri::command]
async fn instances_list() -> Result<Vec<Value>, String> {
    Ok(instances::list())
}

#[tauri::command]
async fn instance_create(name: String) -> Result<Vec<Value>, String> {
    instances::create(&name)?;
    Ok(instances::list())
}

#[tauri::command]
async fn instance_delete(id: String) -> Result<Vec<Value>, String> {
    instances::delete(&id)
}

#[tauri::command]
async fn instance_bind(id: String, account_id: Option<String>) -> Result<Vec<Value>, String> {
    instances::bind(&id, account_id)
}

#[tauri::command]
async fn instance_launch(id: String) -> Result<String, String> {
    instances::launch(&id)
}

// MARK: - Autostart (HKCU Run key, no admin rights needed)

#[tauri::command]
async fn autostart_get() -> Result<bool, String> {
    #[cfg(windows)]
    {
        let mut command = std::process::Command::new("reg");
        command.args([
            "query",
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            "/v",
            "MelonTools",
        ]);
        hidden_command(&mut command);
        Ok(command
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false))
    }
    #[cfg(not(windows))]
    Ok(false)
}

#[tauri::command]
async fn autostart_set(enabled: bool) -> Result<bool, String> {
    #[cfg(windows)]
    {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let mut command = std::process::Command::new("reg");
        if enabled {
            let value = format!("\"{}\"", exe.to_string_lossy());
            command.args([
                "add",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                "/v",
                "MelonTools",
                "/t",
                "REG_SZ",
                "/d",
                &value,
                "/f",
            ]);
        } else {
            command.args([
                "delete",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                "/v",
                "MelonTools",
                "/f",
            ]);
        }
        hidden_command(&mut command);
        let output = command.output().map_err(|e| e.to_string())?;
        Ok(output.status.success())
    }
    #[cfg(not(windows))]
    {
        let _ = enabled;
        Ok(false)
    }
}

// MARK: - Updater (GitHub releases)

/// Latest release lookup. `force=false` throttles to once per 24 h.
#[tauri::command]
async fn update_check(state: State<'_, AppState>, force: bool) -> Result<Value, String> {
    let settings = state.settings();
    let result =
        updater::check(force, env!("CARGO_PKG_VERSION"), settings.last_update_check).await?;
    if result.get("skipped").and_then(|v| v.as_bool()) != Some(true) {
        let now = chrono::Utc::now().timestamp();
        mutate_settings(&state, |s| s.last_update_check = Some(now))?;
        // The latest check replaces the apply target: a release that is no
        // longer newer/verifiable must not leave an older cache behind.
        let cached = updater::cached_from_check(&result);
        if let Ok(mut guard) = state.update.lock() {
            *guard = cached;
        }
    }
    Ok(result)
}

/// Downloads and verifies the new executable, then hands the swap to a
/// detached script and exits so the file is not locked.
///
/// The `url`/`digest` arguments are kept for UI compatibility but ignored: the
/// download target comes exclusively from the last validated `update_check`
/// cached in app state.
#[tauri::command]
async fn update_apply(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    url: String,
    digest: Option<String>,
) -> Result<Value, String> {
    let _ = (url, digest);
    let info = state
        .update
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
        .ok_or_else(|| {
            "нет проверенных данных об обновлении — проверьте обновления ещё раз".to_string()
        })?;
    updater::validate_cached(&info)?;
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    let new_exe = updater::fetch_update(&info.url, Some(&info.digest)).await?;
    updater::spawn_swapper(&new_exe, &current, std::process::id())?;
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        handle.exit(0);
    });
    Ok(json!({ "ok": true }))
}

// MARK: - Providers

#[tauri::command]
async fn openrouter_refresh(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    providers::openrouter(&settings.openrouter_key).await
}

#[tauri::command]
async fn vercel_refresh(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    let mut value = providers::vercel(&settings.vercel_key).await?;
    value["updatedAt"] = json!(chrono::Utc::now().to_rfc3339());
    Ok(value)
}

/// Validates a key, fetches the filtered model list and returns it together
/// with its count. The UI saves the list through `settings_set`; the backend
/// emits it explicitly into the gateway config.
#[tauri::command]
async fn provider_models_load(
    state: State<'_, AppState>,
    provider: String,
) -> Result<Value, String> {
    let settings = state.settings();
    let models = match provider.as_str() {
        "deepinfra" => providers::deepinfra_models(&settings.deepinfra_key).await?,
        "vercel" => providers::vercel_models(&settings.vercel_key).await?,
        "zai" => providers::zai_models(&settings.zai_key).await?,
        other => return Err(format!("неизвестный провайдер: {other}")),
    };
    Ok(json!({ "models": models, "count": models.len() }))
}

// MARK: - Claude provider (engine management API)

fn management(state: &State<'_, AppState>) -> Result<claude::Management, String> {
    let settings = state.settings();
    claude::Management::new(&settings)
}

/// Starts the engine-managed OAuth login: returns the authorization URL (the
/// UI opens it through `open_url`) and the state token used for polling.
#[tauri::command]
async fn claude_login_start(state: State<'_, AppState>) -> Result<Value, String> {
    management(&state)?.login_start().await
}

#[tauri::command]
async fn claude_login_status(
    state: State<'_, AppState>,
    state_token: String,
) -> Result<Value, String> {
    management(&state)?.login_status(&state_token).await
}

#[tauri::command]
async fn claude_login_cancel(
    state: State<'_, AppState>,
    state_token: String,
) -> Result<Value, String> {
    management(&state)?.login_cancel(&state_token).await
}

#[tauri::command]
async fn claude_credentials(state: State<'_, AppState>) -> Result<Value, String> {
    management(&state)?.credentials().await
}

/// Claude model ids served by the running gateway (`/v1/models`), with
/// Antigravity-owned ids removed.
#[tauri::command]
async fn claude_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    antigravity::claude_models_without_antigravity(settings.port, &settings.api_key).await
}

/// Account status + quota windows for the Claude card.
#[tauri::command]
async fn claude_usage(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    providers::claude(&settings).await
}

/// Disconnects every Claude account: removes ALL engine-written
/// `claude-*.json` auth files (the engine hot-reloads the auth dir) and
/// reports what is left. There is no per-account selection here.
#[tauri::command]
async fn claude_disconnect() -> Result<Value, String> {
    let mut removed = 0usize;
    for file in claude::auth_files() {
        if std::fs::remove_file(&file.path).is_ok() {
            removed += 1;
        }
    }
    Ok(json!({ "removed": removed, "remaining": claude::auth_files().len() }))
}

// MARK: - Antigravity provider (engine management API)

fn antigravity_management(state: &State<'_, AppState>) -> Result<antigravity::Management, String> {
    let settings = state.settings();
    antigravity::Management::new(&settings)
}

/// Starts the engine-managed Google OAuth login: returns the authorization URL
/// (the UI opens it through `open_url`) and the state token used for polling.
#[tauri::command]
async fn antigravity_login_start(state: State<'_, AppState>) -> Result<Value, String> {
    antigravity_management(&state)?.login_start().await
}

#[tauri::command]
async fn antigravity_login_status(
    state: State<'_, AppState>,
    state_token: String,
) -> Result<Value, String> {
    antigravity_management(&state)?
        .login_status(&state_token)
        .await
}

#[tauri::command]
async fn antigravity_login_cancel(
    state: State<'_, AppState>,
    state_token: String,
) -> Result<Value, String> {
    antigravity_management(&state)?
        .login_cancel(&state_token)
        .await
}

/// Antigravity credential entries written by the engine.
#[tauri::command]
async fn antigravity_credentials(state: State<'_, AppState>) -> Result<Value, String> {
    antigravity_management(&state)?.credentials().await
}

/// Antigravity model ids served by the running gateway (`/v1/models`).
#[tauri::command]
async fn antigravity_models(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    antigravity::models(settings.port, &settings.api_key).await
}

/// Account identity + model count for the Antigravity card. No quota values:
/// the engine exposes no Antigravity quota endpoint.
#[tauri::command]
async fn antigravity_metrics(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    providers::antigravity(&settings).await
}

/// Disconnects every Antigravity account: removes only the engine-written
/// `antigravity*.json` auth files and reports what is left.
#[tauri::command]
async fn antigravity_account_action(
    state: State<'_, AppState>,
    action: String,
    name: String,
    auth_index: Option<String>,
    model: Option<String>,
    models: Option<Vec<String>>,
    value: Option<i64>,
) -> Result<Value, String> {
    match action.as_str() {
        "remove" => Ok(json!({ "ok": antigravity::remove_auth_file(&name) })),
        "pause" | "resume" => {
            let manager = antigravity_management(&state)?;
            let disabled = action == "pause";
            Ok(json!({
                "ok": manager.set_disabled(&name, auth_index.as_deref(), disabled).await
            }))
        }
        "priority" => {
            let manager = antigravity_management(&state)?;
            Ok(json!({
                "ok": manager.set_priority(&name, value.unwrap_or(0)).await
            }))
        }
        "refresh" => {
            let manager = antigravity_management(&state)?;
            Ok(manager.refresh(Some(&name)).await)
        }
        "probe" => {
            let settings = state.settings();
            let targets = antigravity::probe_targets(models, model);
            Ok(json!({
                "ok": antigravity::probe_account(
                    &settings,
                    &name,
                    auth_index.as_deref().unwrap_or_default(),
                    &targets,
                )
                .await
            }))
        }
        other => Err(format!("unknown antigravity action: {other}")),
    }
}

#[tauri::command]
async fn antigravity_disconnect() -> Result<Value, String> {
    let (removed, remaining) = antigravity::disconnect_in(&paths::auths_dir());
    Ok(json!({ "removed": removed, "remaining": remaining }))
}

/// Launcher argv for an http(s) URL. The browser is opened through
/// `rundll32 url.dll,FileProtocolHandler`: unlike `cmd /C start`, no shell
/// re-parses the URL, so quotes, `&` or `^` cannot inject another command.
fn launcher_argv(url: &str) -> Result<[String; 2], String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("разрешены только http(s)-ссылки".to_string());
    }
    Ok(["url.dll,FileProtocolHandler".to_string(), url.to_string()])
}

/// Opens an http(s) URL in the default browser (device login page).
#[tauri::command]
async fn open_url(url: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        let argv = launcher_argv(&url)?;
        let mut command = std::process::Command::new("rundll32.exe");
        command.args(argv);
        hidden_command(&mut command);
        command.spawn().map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        launcher_argv(&url)?;
        Err("открытие ссылок поддерживается на Windows".to_string())
    }
}

// MARK: - Entry point

/// Restarts the engine when it dies while we believe it should run.
async fn watchdog_check(state: &AppState, app: &tauri::AppHandle) {
    let (supervised, user_stopped, misses, restarts) = match state.watchdog.lock() {
        Ok(guard) => (
            guard.supervised,
            guard.user_stopped,
            guard.misses,
            guard.restarts,
        ),
        Err(_) => return,
    };
    if !supervised || user_stopped || restarts >= 3 {
        return;
    }
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        if let Ok(mut guard) = state.watchdog.lock() {
            guard.misses = 0;
            guard.health_ok = true;
        }
        // A long-running engine keeps `gateway.log` open, so the file can only
        // be rotated by a restart. Rotate once per session, and only while the
        // pool is idle so an active stream is never cut.
        let needs_rotation = gateway::log_size() > 32 * 1024 * 1024
            && gateway::requests_last_minute() == 0
            && state
                .watchdog
                .lock()
                .map(|guard| !guard.log_rotated)
                .unwrap_or(false);
        if needs_rotation {
            let _ = gateway::stop(&state.gw);
            let outcome = gateway::start(&state.gw, &settings).await;
            if let Ok(mut guard) = state.watchdog.lock() {
                guard.log_rotated = outcome.is_ok();
            }
            return;
        }
        // Keep the catalog overlay on the engine's refresh cadence. It is
        // written outside the watchdog path so a slow fetch cannot delay the
        // next health probe; a new file also rewrites the config in case the
        // overlay appeared after the gateway started.
        if crate::catalog::needs_refresh() && !crate::catalog::is_refreshing() {
            let handle = app.clone();
            tauri::async_runtime::spawn(async move {
                if crate::catalog::refresh_in_background().await {
                    let state = handle.state::<AppState>();
                    let settings = state.settings();
                    let _ = crate::gateway::write_config(&settings);
                }
            });
        }
        return;
    }
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.health_ok = false;
    }
    let missed = misses + 1;
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.misses = missed;
    }
    if missed < 2 {
        return;
    }
    // Every attempt counts toward the bound (a persistently failing start
    // must not retry forever), and the miss counter resets so a failed
    // attempt is followed by a fresh two-miss wait instead of a hot loop.
    let outcome = gateway::start(&state.gw, &settings).await;
    if let Ok(mut guard) = state.watchdog.lock() {
        guard.misses = 0;
        guard.restarts += 1;
        if outcome.is_ok() {
            guard.health_ok = true;
            guard.last_restart = Some(chrono::Utc::now().to_rfc3339());
        }
    }
}

/// Single-instance ownership lives in `tauri-plugin-single-instance`: on
/// Windows it uses a named mutex, so a crash releases it automatically and a
/// stale `app.lock` file can never block the next launch. The plugin also
/// calls the callback below in the first instance, which is what raises the
/// window out of the tray instead of silently exiting.
fn show_main_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum ApiToggle {
    Start,
    Stop,
}

/// Pause a running gateway; start it again when it is stopped or the user
/// explicitly stopped it earlier.
fn api_toggle_action(running: bool, user_stopped: bool) -> ApiToggle {
    if user_stopped || !running {
        ApiToggle::Start
    } else {
        ApiToggle::Stop
    }
}

/// Frontend payload for the tray items that the webview owns. Show, API toggle
/// and Quit are handled entirely in Rust.
fn tray_event_payload(menu_id: &str) -> Option<Value> {
    match menu_id {
        "scheduler" => Some(json!({"action": "navigate", "section": "scheduler"})),
        "run-next" => Some(json!({"action": "run-next"})),
        _ => None,
    }
}

fn handle_tray_menu(app: &tauri::AppHandle, menu_id: &str) {
    match menu_id {
        "show" => show_main_window(app),
        "scheduler" | "run-next" => {
            show_main_window(app);
            if let Some(payload) = tray_event_payload(menu_id) {
                let _ = app.emit("tray-action", payload);
            }
        }
        "api-toggle" => {
            let handle = app.clone();
            tauri::async_runtime::spawn(async move {
                let state = handle.state::<AppState>();
                let settings = state.settings();
                let running = gateway::health(settings.port, &settings.api_key).await;
                let user_stopped = state
                    .watchdog
                    .lock()
                    .map(|guard| guard.user_stopped)
                    .unwrap_or(false);
                match api_toggle_action(running, user_stopped) {
                    ApiToggle::Start => {
                        let _ = start_gateway(state.inner()).await;
                    }
                    ApiToggle::Stop => {
                        let _ = stop_gateway(state.inner()).await;
                    }
                }
                let running = gateway::health(settings.port, &settings.api_key).await;
                let _ = handle.emit(
                    "tray-action",
                    json!({"action": "refresh", "running": running}),
                );
            });
        }
        "quit" => {
            // Dropping a std::process::Child does not stop it. Stop the
            // engine before exiting so no unauthenticated gateway survives
            // the app in the background.
            let state = app.state::<AppState>();
            let _ = gateway::stop(&state.gw);
            app.exit(0);
        }
        _ => {}
    }
}

fn tray_labels(lang: &str) -> [&'static str; 5] {
    if lang == "en" {
        [
            "Show",
            "Scheduler",
            "Run next task",
            "Pause / Resume API",
            "Quit",
        ]
    } else {
        [
            "Показать",
            "Планировщик",
            "Выполнить следующую задачу",
            "Пауза / Возобновить API",
            "Выход",
        ]
    }
}

fn build_tray_menu(
    app: &tauri::AppHandle,
    lang: &str,
) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    let [show, scheduler, run_next, api, quit] = tray_labels(lang);
    let show_item = tauri::menu::MenuItem::with_id(app, "show", show, true, None::<&str>)?;
    let scheduler_item =
        tauri::menu::MenuItem::with_id(app, "scheduler", scheduler, true, None::<&str>)?;
    let run_item = tauri::menu::MenuItem::with_id(app, "run-next", run_next, true, None::<&str>)?;
    let api_item = tauri::menu::MenuItem::with_id(app, "api-toggle", api, true, None::<&str>)?;
    let quit_item = tauri::menu::MenuItem::with_id(app, "quit", quit, true, None::<&str>)?;
    tauri::menu::Menu::with_items(
        app,
        &[
            &show_item,
            &scheduler_item,
            &run_item,
            &api_item,
            &quit_item,
        ],
    )
}

/// Rebuild the tray menu after a language switch. Menu labels are native
/// objects created once at startup; without this an English UI kept the
/// Russian tray.
fn refresh_tray_menu(app: &tauri::AppHandle, lang: &str) -> tauri::Result<()> {
    let Some(tray) = app.tray_by_id("main-tray") else {
        return Ok(());
    };
    tray.set_menu(Some(build_tray_menu(app, lang)?))
}

// MARK: - Status island

/// Resting size of the island. The card keeps the same height in both states
/// and only widens when it opens.
const ISLAND_WIDTH: f64 = 185.0;
const ISLAND_COMPACT_HEIGHT: f64 = 30.0;
const ISLAND_PANEL_WIDTH: f64 = 420.0;
const ISLAND_PANEL_HEIGHT: f64 = 242.0;

/// Centres one island window on the primary monitor, flush with the top of its
/// work area, and applies the requested logical size.
fn place_window(app: &tauri::AppHandle, label: &str, width: f64, height: f64) -> tauri::Result<()> {
    let Some(window) = app.get_webview_window(label) else {
        return Ok(());
    };
    window.set_size(tauri::LogicalSize::new(width, height))?;
    let monitor = app
        .primary_monitor()?
        .or_else(|| window.current_monitor().ok().flatten());
    let Some(monitor) = monitor else {
        return Ok(());
    };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let pixel_width = (width * scale).round() as i32;
    let max_x = area.position.x + area.size.width as i32 - pixel_width;
    let x = (area.position.x + (area.size.width as i32 - pixel_width) / 2)
        .clamp(area.position.x, max_x.max(area.position.x));
    window.set_position(tauri::PhysicalPosition::new(x, area.position.y))?;
    Ok(())
}

fn place_island(app: &tauri::AppHandle, width: f64, height: f64) -> tauri::Result<()> {
    place_window(app, "island", width, height)
}

fn build_island_window(app: &tauri::AppHandle) -> Option<tauri::WebviewWindow> {
    let window = tauri::WebviewWindowBuilder::new(
        app,
        "island",
        tauri::WebviewUrl::App("island.html".into()),
    )
    .title("Melon HUD")
    .inner_size(ISLAND_WIDTH, ISLAND_COMPACT_HEIGHT)
    .decorations(false)
    .transparent(true)
    .shadow(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .focused(false)
    .resizable(false)
    .visible(false)
    .build();
    let window = match window {
        Ok(window) => window,
        Err(error) => {
            eprintln!("island window: {error}");
            return None;
        }
    };
    // A click on the island must not pull focus out of the app the user is
    // working in; WS_EX_NOACTIVATE still lets the webview receive the click.
    let _ = window.set_focusable(false);
    let _ = place_island(app, ISLAND_WIDTH, ISLAND_COMPACT_HEIGHT);
    Some(window)
}

/// The expanded card is a second, already-sized window. Showing it never
/// depends on WebView2 resizing its surface.
fn build_island_panel(app: &tauri::AppHandle) -> Option<tauri::WebviewWindow> {
    let window = tauri::WebviewWindowBuilder::new(
        app,
        "island-panel",
        tauri::WebviewUrl::App("island.html".into()),
    )
    .title("Melon HUD Panel")
    .inner_size(ISLAND_PANEL_WIDTH, ISLAND_PANEL_HEIGHT)
    .initialization_script("window.__melonMode = 'expanded';")
    .decorations(false)
    .transparent(true)
    .shadow(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .focused(false)
    .resizable(false)
    .visible(false)
    .build();
    let window = match window {
        Ok(window) => window,
        Err(error) => {
            eprintln!("island panel window: {error}");
            return None;
        }
    };
    let _ = window.set_focusable(false);
    let _ = place_window(app, "island-panel", ISLAND_PANEL_WIDTH, ISLAND_PANEL_HEIGHT);
    Some(window)
}

fn emit_island_visibility(app: &tauri::AppHandle, visible: bool) {
    for label in ["island", "island-panel"] {
        if let Some(window) = app.get_webview_window(label) {
            let _ = window.emit("island-visibility", visible);
        }
    }
}

fn set_island_visible(app: &tauri::AppHandle, visible: bool) {
    if visible {
        if app.get_webview_window("island-panel").is_none() {
            let _ = build_island_panel(app);
        }
        let panel_open = app
            .get_webview_window("island-panel")
            .and_then(|panel| panel.is_visible().ok())
            .unwrap_or(false);
        if !panel_open {
            if let Some(compact) = app
                .get_webview_window("island")
                .or_else(|| build_island_window(app))
            {
                let _ = compact.show();
            }
            if let Some(panel) = app.get_webview_window("island-panel") {
                let _ = panel.hide();
            }
        }
    } else {
        for label in ["island", "island-panel"] {
            if let Some(window) = app.get_webview_window(label) {
                let _ = window.hide();
            }
        }
    }
    emit_island_visibility(app, visible);
}

/// Every upstream the gateway can use, matching the dashboard's count.
fn island_provider_count(settings: &settings::Settings, codex_accounts: usize) -> usize {
    let mut count = 0;
    if settings.openrouter_enabled && !settings.openrouter_key.is_empty() {
        count += 1;
    }
    if settings.opencode_enabled && !settings.opencode_key.is_empty() {
        count += 1;
    }
    if settings.deepinfra_enabled && !settings.deepinfra_key.is_empty() {
        count += 1;
    }
    if settings.vercel_enabled && !settings.vercel_key.is_empty() {
        count += 1;
    }
    if settings.zai_enabled && !settings.zai_key.is_empty() {
        count += 1;
    }
    if settings.claude_enabled {
        count += 1;
    }
    if codex_accounts > 0 {
        count += 1;
    }
    count
}

/// Everything the island renders, in one round trip.
///
/// The renderer polls this every few seconds. A short cache keeps the disk and
/// the health probe out of that loop; the payload contains only counts, never
/// tokens.
#[tauri::command]
async fn island_snapshot(state: State<'_, AppState>) -> Result<Value, String> {
    if let Ok(guard) = state.island.lock() {
        if let Some((at, value)) = guard.as_ref() {
            if at.elapsed() < Duration::from_secs(4) {
                return Ok(value.clone());
            }
        }
    }
    let value = build_island_snapshot(state.inner()).await;
    if let Ok(mut guard) = state.island.lock() {
        *guard = Some((Instant::now(), value.clone()));
    }
    Ok(value)
}

async fn build_island_snapshot(state: &AppState) -> Value {
    let settings = state.settings();
    let running = gateway::health(settings.port, &settings.api_key).await;
    let accounts = vault::list_views();
    let hourly: Vec<f64> = accounts
        .iter()
        .filter_map(|account| account.get("hourlyRemaining").and_then(Value::as_f64))
        .collect();
    let weekly: Vec<f64> = accounts
        .iter()
        .filter_map(|account| account.get("weeklyRemaining").and_then(Value::as_f64))
        .collect();
    let summary = scheduler::summary();
    json!({
        "lang": settings.lang,
        "gateway": { "running": running, "port": settings.port },
        "codex": {
            "accounts": accounts.len(),
            "hourly": if hourly.is_empty() { Value::Null } else { Value::from(hourly.iter().sum::<f64>()) },
            "weekly": if weekly.is_empty() { Value::Null } else { Value::from(weekly.iter().sum::<f64>()) },
            "max": (accounts.len() as f64) * 100.0,
        },
        "antigravity": { "accounts": antigravity::auth_files().len() },
        "scheduler": {
            "due": summary.get("dueCount").cloned().unwrap_or(json!(0)),
            "nextRunAt": summary.get("nextRunAt").cloned().unwrap_or(Value::Null),
            "running": summary.get("running").cloned().unwrap_or(Value::Null),
        },
        "providers": island_provider_count(&settings, accounts.len()),
    })
}

#[tauri::command]
fn island_resize(app: tauri::AppHandle, width: f64, height: f64) -> Result<(), String> {
    let width = width.clamp(120.0, 720.0);
    let height = height.clamp(24.0, 480.0);
    place_island(&app, width, height).map_err(|error| error.to_string())
}

#[tauri::command]
fn island_expand(app: tauri::AppHandle) -> Result<(), String> {
    if !app.state::<AppState>().settings().island_visible {
        return Ok(());
    }
    let compact = app
        .get_webview_window("island")
        .or_else(|| build_island_window(&app))
        .ok_or_else(|| "island window unavailable".to_string())?;
    let panel = app
        .get_webview_window("island-panel")
        .or_else(|| build_island_panel(&app))
        .ok_or_else(|| "island panel unavailable".to_string())?;
    place_window(
        &app,
        "island-panel",
        ISLAND_PANEL_WIDTH,
        ISLAND_PANEL_HEIGHT,
    )
    .map_err(|error| error.to_string())?;
    let _ = panel.set_focusable(false);
    panel.show().map_err(|error| error.to_string())?;
    let _ = compact.hide();
    Ok(())
}

#[tauri::command]
fn island_collapse(app: tauri::AppHandle) -> Result<(), String> {
    if !app.state::<AppState>().settings().island_visible {
        return Ok(());
    }
    let compact = app
        .get_webview_window("island")
        .or_else(|| build_island_window(&app))
        .ok_or_else(|| "island window unavailable".to_string())?;
    place_island(&app, ISLAND_WIDTH, ISLAND_COMPACT_HEIGHT).map_err(|error| error.to_string())?;
    compact.show().map_err(|error| error.to_string())?;
    if let Some(panel) = app.get_webview_window("island-panel") {
        let _ = panel.hide();
    }
    Ok(())
}

#[tauri::command]
fn island_reposition(app: tauri::AppHandle) -> Result<(), String> {
    for (label, width, height) in [
        ("island", ISLAND_WIDTH, ISLAND_COMPACT_HEIGHT),
        ("island-panel", ISLAND_PANEL_WIDTH, ISLAND_PANEL_HEIGHT),
    ] {
        if app.get_webview_window(label).is_some() {
            place_window(&app, label, width, height).map_err(|error| error.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
fn island_open_main(app: tauri::AppHandle) {
    show_main_window(&app);
}

#[tauri::command]
async fn island_toggle_api(state: State<'_, AppState>) -> Result<Value, String> {
    if let Ok(mut guard) = state.island.lock() {
        *guard = None;
    }
    let settings = state.settings();
    let running = gateway::health(settings.port, &settings.api_key).await;
    let user_stopped = state
        .watchdog
        .lock()
        .map(|guard| guard.user_stopped)
        .unwrap_or(false);
    match api_toggle_action(running, user_stopped) {
        ApiToggle::Start => {
            let _ = start_gateway(state.inner()).await;
        }
        ApiToggle::Stop => {
            let _ = stop_gateway(state.inner()).await;
        }
    }
    let running = gateway::health(settings.port, &settings.api_key).await;
    if let Ok(mut guard) = state.island.lock() {
        *guard = None;
    }
    Ok(json!({ "running": running }))
}

#[tauri::command]
async fn island_run_next(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<Value, String> {
    let settings = state.settings();
    let store = scheduler::load();
    let Some(task) = scheduler::due_task(&store, scheduler::now_secs()) else {
        return Ok(json!({ "ran": false }));
    };
    let id = task.id.clone();
    let task_id = id.clone();
    if let Ok(mut guard) = state.island.lock() {
        *guard = None;
    }
    tauri::async_runtime::spawn(async move {
        let _ = scheduler::run_now(&settings, &task_id, &app).await;
    });
    Ok(json!({ "ran": true, "id": id }))
}

fn main() {
    // Installer uninstall hook: restore Codex's config while the exe still
    // exists, so a removed app does not leave Codex pointed at a dead port.
    if std::env::args().any(|arg| arg == "--restore-codex-route") {
        let _ = codex_route::remove();
        return;
    }
    let initial_settings = settings::load();
    let initial_lang = initial_settings.lang.clone();
    let island_visible = initial_settings.island_visible;

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // A desktop shortcut or a tray double-click while the app is
            // hidden must show the existing window, not start a second app.
            show_main_window(app);
        }))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState {
            gw: gateway::Gateway::new(),
            bridge: bridge::BridgeState::new(),
            settings: Mutex::new(initial_settings),
            watchdog: Mutex::new(Watchdog::default()),
            update: Mutex::new(None),
            island: Mutex::new(None),
        })
        .setup(move |app| {
            // System tray: window, scheduler navigation, run-next, API
            // pause/resume and quit. Labels follow the saved UI language and
            // are rebuilt by `settings_set` when it changes.
            let menu = build_tray_menu(app.handle(), &initial_lang)?;
            let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/icon.png"))?;
            tauri::tray::TrayIconBuilder::with_id("main-tray")
                .icon(icon)
                .menu(&menu)
                // Left click opens the window; the context menu belongs to the
                // right click. With the default (menu on left click too) the
                // window focus could dismiss the popup as it opened.
                .show_menu_on_left_click(false)
                .tooltip("Melon Tools")
                .on_menu_event(|app, event| handle_tray_menu(app, event.id.as_ref()))
                .on_tray_icon_event(|tray, event| {
                    // Only a left click opens the window. Handling every click
                    // here stole focus from the right-click menu on Windows,
                    // so the menu flashed and closed immediately.
                    if let tauri::tray::TrayIconEvent::Click {
                        button: tauri::tray::MouseButton::Left,
                        button_state: tauri::tray::MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main_window(tray.app_handle());
                    }
                })
                .build(app)?;

            if island_visible {
                build_island_window(app.handle());
                build_island_panel(app.handle());
                set_island_visible(app.handle(), true);
            }

            // Auto-start the gateway, point Codex at it, then keep the chips
            // bridge ticking every 5 seconds.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                {
                    let state = handle.state::<AppState>();
                    let settings = state.settings();
                    if gateway::start(&state.gw, &settings).await.is_ok() {
                        if let Ok(client) = quota::local_client() {
                            let _ = codex_route::sync_catalog(
                                &client,
                                settings.port,
                                &settings.api_key,
                            )
                            .await;
                        }
                        if codex_route::catalog_path().exists() {
                            let _ = codex_route::apply(settings.port, &settings.api_key);
                        }
                        // Arm the watchdog: without this the auto-started
                        // engine would get no auto-restart after a crash.
                        if let Ok(mut guard) = state.watchdog.lock() {
                            guard.supervised = true;
                            guard.user_stopped = false;
                            guard.misses = 0;
                            guard.health_ok = true;
                        }
                    }
                }
                let mut tick: u64 = 0;
                loop {
                    {
                        let state = handle.state::<AppState>();
                        let settings = state.settings();
                        bridge::tick(&state.bridge, &settings).await;
                        tick += 1;
                        if tick.is_multiple_of(6) {
                            watchdog_check(&state, &handle).await;
                        }
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                }
            });

            // Scheduler: one due task per 30 s tick, serial with "Run now".
            // It runs only while this process is alive — no background service.
            let scheduler_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    let settings = {
                        let state = scheduler_handle.state::<AppState>();
                        state.settings()
                    };
                    scheduler::tick(&settings, &scheduler_handle).await;
                    tokio::time::sleep(std::time::Duration::from_secs(scheduler::TICK_SECS)).await;
                }
            });

            // Quota refresh and low/reset notifications belong to the Rust
            // process, not the WebView timer: WebView2 may throttle or suspend
            // timers when the window is hidden to the tray.
            let quota_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut last = std::time::Instant::now() - std::time::Duration::from_secs(300);
                loop {
                    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                    let state = quota_handle.state::<AppState>();
                    let settings = state.settings();
                    if !gateway::health(settings.port, &settings.api_key).await {
                        continue;
                    }
                    let interval = settings.quota_interval.max(60) as u64;
                    let urgent = gateway::requests_last_minute() > 0;
                    let due = last.elapsed()
                        >= std::time::Duration::from_secs(if urgent { 30 } else { interval });
                    if !due {
                        continue;
                    }
                    last = std::time::Instant::now();
                    let Ok(client) = quota::client() else {
                        continue;
                    };
                    let previous = quota_snapshot();
                    let _ = quota::refresh_all(&client, None).await;
                    let settings = state.settings();
                    // Clear recovered sticky pauses before the reset toast is
                    // computed; otherwise the fresh reading is masked by the
                    // persisted block until the next 1.5-second tick.
                    live_quota::tick(&settings).await;
                    let _ = gateway::sync_accounts(&settings);
                    check_low_quota(&quota_handle, &state, &previous);
                    check_quota_reset(&quota_handle, &state, &previous);
                }
            });

            // Keep passive quota enforcement in the native process. WebView2
            // timers can be throttled while the app is hidden to the tray.
            let live_quota_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    let state = live_quota_handle.state::<AppState>();
                    // Do not poll the management API while the engine is
                    // stopped. `child_running` covers engines we spawned;
                    // `watchdog.supervised` covers an adopted engine.
                    let supervised = state
                        .watchdog
                        .lock()
                        .map(|watchdog| watchdog.supervised && !watchdog.user_stopped)
                        .unwrap_or(false);
                    let healthy = state
                        .watchdog
                        .lock()
                        .map(|watchdog| watchdog.health_ok)
                        .unwrap_or(false);
                    if !state.gw.child_running() && !(supervised && healthy) {
                        tokio::time::sleep(std::time::Duration::from_secs(15)).await;
                        continue;
                    }
                    let settings = state.settings();
                    let fast = live_quota::tick(&settings).await;
                    // 1.5 s only while a blocked window is about to reset;
                    // otherwise this guard would hit the management API and
                    // the gateway log 40 times a minute for days.
                    let delay = if fast { 1_500 } else { 15_000 };
                    tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
                }
            });
            Ok(())
        })
        // Closing the window must not stop the scheduler: hide it to the tray
        // and keep the process (and the 30 s tick) alive. Quit is explicit in
        // the tray menu.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            app_info,
            support_bundle,
            settings_get,
            settings_set,
            gateway_status,
            gateway_start,
            gateway_stop,
            gateway_sync,
            gateway_check,
            gateway_recent_calls,
            gateway_models,
            vault_list,
            quota_refresh,
            reset_activate,
            quota_history,
            switch_account,
            import_current_auth,
            import_json_accounts,
            account_refresh_tokens,
            save_reserves,
            delete_account,
            device_login_start,
            device_login_poll,
            routing_state,
            set_routing_strategy,
            move_priority,
            reset_priority,
            set_account_role,
            codex_route_status,
            catalog_sync,
            codex_route_apply,
            codex_route_remove,
            codex_app_status,
            codex_app_set_path,
            codex_app_forget_path,
            codex_app_open,
            codex_pool_models,
            codex_models_refresh,
            save_account_models,
            set_pool_model,
            apply_codex_models,
            bridge_status,
            bridge_launch_codex,
            scheduler_list,
            scheduler_summary,
            scheduler_tasks,
            scheduler_history,
            scheduler_result,
            scheduler_save,
            scheduler_delete,
            scheduler_run_now,
            scheduler_cancel,
            scheduler_queue,
            scheduler_models,
            backup_export,
            backup_import,
            backup_last,
            instances_list,
            instance_create,
            instance_delete,
            instance_bind,
            instance_launch,
            autostart_get,
            autostart_set,
            update_check,
            update_apply,
            openrouter_refresh,
            vercel_refresh,
            provider_models_load,
            claude_login_start,
            claude_login_status,
            claude_login_cancel,
            claude_credentials,
            claude_models,
            claude_usage,
            claude_disconnect,
            antigravity_login_start,
            antigravity_login_status,
            antigravity_login_cancel,
            antigravity_credentials,
            antigravity_models,
            antigravity_metrics,
            antigravity_disconnect,
            antigravity_account_action,
            open_url,
            island_snapshot,
            island_resize,
            island_expand,
            island_collapse,
            island_reposition,
            island_open_main,
            island_toggle_api,
            island_run_next,
        ])
        .run(tauri::generate_context!())
        .expect("Melon Tools failed to start");
}

#[cfg(test)]
mod tests {
    use super::{
        api_toggle_action, launcher_argv, pool_snapshot_of, pool_toggle_plan,
        pool_toggle_selection, settings_view, tray_event_payload, ApiToggle,
    };
    use std::collections::HashSet;

    #[test]
    fn tray_events_map_to_frontend_actions() {
        let scheduler = tray_event_payload("scheduler").unwrap();
        assert_eq!(scheduler["action"], "navigate");
        assert_eq!(scheduler["section"], "scheduler");
        let run = tray_event_payload("run-next").unwrap();
        assert_eq!(run["action"], "run-next");
        assert!(tray_event_payload("show").is_none());
        assert!(tray_event_payload("api-toggle").is_none());
        assert!(tray_event_payload("unknown").is_none());
    }

    #[test]
    fn api_toggle_pauses_only_a_running_gateway() {
        assert_eq!(api_toggle_action(true, false), ApiToggle::Stop);
        assert_eq!(api_toggle_action(false, false), ApiToggle::Start);
        assert_eq!(api_toggle_action(true, true), ApiToggle::Start);
        assert_eq!(api_toggle_action(false, true), ApiToggle::Start);
    }

    #[test]
    fn launcher_accepts_only_http_schemes() {
        assert_eq!(
            launcher_argv("https://example.com/login?x=1&y=2").unwrap(),
            [
                "url.dll,FileProtocolHandler".to_string(),
                "https://example.com/login?x=1&y=2".to_string()
            ]
        );
        assert!(launcher_argv("http://127.0.0.1:18317/").is_ok());
        for bad in [
            "file:///C:/Windows/System32/cmd.exe",
            "javascript:alert(1)",
            "shell:startup",
            "ms-settings:",
            "cmd /C calc",
        ] {
            assert!(launcher_argv(bad).is_err(), "accepted {bad}");
        }
    }

    #[test]
    fn settings_view_redacts_the_management_secret() {
        let mut settings = crate::settings::Settings::default();
        settings.port = 19000;
        settings.management_secret = "melon-mgmt-0123456789abcdef".to_string();
        let value = settings_view(&settings).unwrap();
        assert_eq!(value["managementSecret"], "");
        assert_eq!(value["port"], 19000);
        assert!(!value.to_string().contains("melon-mgmt-"));
    }

    fn pool_set(slugs: &[&str]) -> HashSet<String> {
        slugs.iter().map(|slug| slug.to_string()).collect()
    }

    fn account(id: &str, email: &str, selected: Option<&[&str]>) -> crate::vault::Account {
        crate::vault::Account {
            id: id.to_string(),
            email: Some(email.to_string()),
            selected_models: selected.map(|slugs| slugs.iter().map(|s| s.to_string()).collect()),
            ..Default::default()
        }
    }

    #[test]
    fn pool_toggle_never_empties_an_account() {
        let both = pool_set(&["gpt-5", "gpt-5-mini"]);
        assert_eq!(
            pool_toggle_selection(&both, "gpt-5", false).unwrap(),
            vec!["gpt-5-mini".to_string()]
        );
        assert_eq!(
            pool_toggle_selection(&both, "gpt-5", true).unwrap(),
            vec!["gpt-5".to_string(), "gpt-5-mini".to_string()]
        );
        let single = pool_set(&["gpt-5"]);
        assert!(pool_toggle_selection(&single, "gpt-5", false).is_none());
        assert_eq!(
            pool_toggle_selection(&single, "gpt-5", true).unwrap(),
            vec!["gpt-5".to_string()]
        );
    }

    #[test]
    fn pool_toggle_plan_is_all_or_nothing() {
        let all = pool_set(&["gpt-5", "gpt-5-mini"]);
        let accounts = vec![
            account("one", "one@example.com", Some(&["gpt-5", "gpt-5-mini"])),
            account("two", "two@example.com", Some(&["gpt-5-mini"])),
        ];
        let plan = pool_toggle_plan(&accounts, &all, "gpt-5", false).unwrap();
        assert_eq!(plan["one"], vec!["gpt-5-mini".to_string()]);
        assert_eq!(plan["two"], vec!["gpt-5-mini".to_string()]);

        let legacy = vec![account("legacy", "legacy@example.com", None)];
        let plan = pool_toggle_plan(&legacy, &all, "gpt-5", false).unwrap();
        assert_eq!(plan["legacy"], vec!["gpt-5-mini".to_string()]);

        let blocked = vec![
            account("one", "one@example.com", Some(&["gpt-5"])),
            account("two", "two@example.com", Some(&["gpt-5-mini"])),
        ];
        let error = pool_toggle_plan(&blocked, &all, "gpt-5", false).unwrap_err();
        assert_eq!(
            error,
            "нельзя изменить gpt-5: one@example.com останется без моделей"
        );
    }

    #[test]
    fn pool_snapshot_counts_selected_accounts() {
        let all = pool_set(&["gpt-5", "gpt-5-mini"]);
        let models = vec![crate::codex_route::PoolModel {
            slug: "gpt-5".to_string(),
            display: "GPT-5".to_string(),
            context_length: Some(128_000),
            priority: 10,
        }];
        let accounts = vec![
            account("one", "one@example.com", Some(&["gpt-5"])),
            account("two", "two@example.com", Some(&[])),
        ];
        let snapshot = pool_snapshot_of(&models, &accounts, &all);
        assert_eq!(snapshot["accountCount"], 2);
        assert_eq!(snapshot["selectedCount"], 1);
        let entry = &snapshot["models"][0];
        assert_eq!(entry["slug"], "gpt-5");
        assert_eq!(entry["display"], "GPT-5");
        assert_eq!(entry["contextLength"], 128_000);
        assert_eq!(entry["priority"], 10);
        assert_eq!(entry["selectedCount"], 1);
        assert_eq!(entry["accountCount"], 2);
    }
}
