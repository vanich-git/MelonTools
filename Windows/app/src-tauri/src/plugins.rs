//! Native CLIProxyAPI plugin store for Windows.
//!
//! The engine owns discovery, install, checksum verification and loading.
//! These commands are a thin management proxy so the renderer never sees the
//! management secret and so destructive or execution-changing calls can be
//! validated against a strict plugin id.

use std::time::Duration;

use serde_json::{json, Value};
use tauri::State;

use crate::{gateway, plugin_settings, AppState};

const PLUGIN_TIMEOUT: Duration = Duration::from_secs(20);
const INSTALL_TIMEOUT: Duration = Duration::from_secs(300);
/// The store response carries a few hundred entries and the largest config is
/// a handful of kilobytes, so 8 MiB is far above any real answer. Without a
/// cap a broken or hostile local listener could stream until the process ran
/// out of memory.
const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

fn client(timeout: Duration) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .no_proxy()
        .timeout(timeout)
        .build()
        .map_err(|e| e.to_string())
}

/// Plugin ids are part of a URL path and later of a file name. Accept only the
/// engine's documented alphabet so a renderer cannot smuggle `../` or a query.
fn valid_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes.len() > 128 || !bytes[0].is_ascii_alphanumeric() {
        return false;
    }
    bytes
        .iter()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn valid_version(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_digit()
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'+' | b'-'))
}

fn encode_component(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn management_base(state: &AppState) -> String {
    format!("http://127.0.0.1:{}/", state.settings().port)
}

fn management_secret(state: &AppState) -> String {
    state.settings().management_secret
}

async fn read_body(response: reqwest::Response) -> Result<String, String> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_RESPONSE_BYTES as u64)
    {
        return Err(format!(
            "the gateway response is larger than {} MiB",
            MAX_RESPONSE_BYTES / (1024 * 1024)
        ));
    }
    let mut body: Vec<u8> = Vec::new();
    let mut response = response;
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        if body.len() + chunk.len() > MAX_RESPONSE_BYTES {
            return Err(format!(
                "the gateway response is larger than {} MiB",
                MAX_RESPONSE_BYTES / (1024 * 1024)
            ));
        }
        body.extend_from_slice(&chunk);
    }
    String::from_utf8(body).map_err(|e| format!("the gateway response is not UTF-8: {e}"))
}

async fn request(
    state: &AppState,
    method: reqwest::Method,
    path: &str,
    body: Option<Value>,
    timeout: Duration,
) -> Result<Value, String> {
    let client = client(timeout)?;
    let url = format!("{}{}", management_base(state), path.trim_start_matches('/'));
    let mut builder = client
        .request(method, url)
        .header(
            "Authorization",
            format!("Bearer {}", management_secret(state)),
        )
        .header("Accept", "application/json");
    if let Some(body) = body {
        builder = builder.json(&body);
    }
    let response = builder.send().await.map_err(|e| e.to_string())?;
    let status = response.status();
    let text = read_body(response).await?;
    if !status.is_success() {
        let (code, message) = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|value| {
                Some((
                    value.get("error")?.as_str()?.to_string(),
                    value
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                ))
            })
            .unwrap_or_default();
        if message.is_empty() {
            return Err(format!("HTTP {}", status.as_u16()));
        }
        return Err(if code.is_empty() {
            message
        } else {
            format!("{code}: {message}")
        });
    }
    if text.trim().is_empty() {
        return Ok(json!({ "ok": true }));
    }
    serde_json::from_str(&text).map_err(|e| format!("invalid management response: {e}"))
}

#[tauri::command]
pub async fn plugins_store(state: State<'_, AppState>) -> Result<Value, String> {
    request(
        state.inner(),
        reqwest::Method::GET,
        "/v8/management/plugins/store",
        None,
        PLUGIN_TIMEOUT,
    )
    .await
}

#[tauri::command]
pub async fn plugins_installed(state: State<'_, AppState>) -> Result<Value, String> {
    request(
        state.inner(),
        reqwest::Method::GET,
        "/v8/management/plugins",
        None,
        PLUGIN_TIMEOUT,
    )
    .await
}

#[tauri::command]
pub async fn plugins_install(
    state: State<'_, AppState>,
    id: String,
    source: Option<String>,
    version: Option<String>,
) -> Result<Value, String> {
    if !valid_id(&id) {
        return Err("invalid plugin id".to_string());
    }
    if !plugin_settings::load().host_enabled {
        return Err("native plugins are off; turn the host on first".to_string());
    }
    let mut path = format!("/v8/management/plugins/store/{id}/install");
    if let Some(source) = source.filter(|value| !value.trim().is_empty()) {
        if !valid_id(source.trim()) {
            return Err("invalid plugin source".to_string());
        }
        path.push_str(&format!("?source={}", encode_component(source.trim())));
    }
    let body = version
        .filter(|value| !value.trim().is_empty())
        .map(|value| {
            if !valid_version(value.trim()) {
                return Err("invalid plugin version".to_string());
            }
            Ok(json!({ "version": value.trim() }))
        })
        .transpose()?;
    request(
        state.inner(),
        reqwest::Method::POST,
        &path,
        body,
        INSTALL_TIMEOUT,
    )
    .await
}

#[tauri::command]
pub async fn plugins_remove(state: State<'_, AppState>, id: String) -> Result<Value, String> {
    if !valid_id(&id) {
        return Err("invalid plugin id".to_string());
    }
    request(
        state.inner(),
        reqwest::Method::DELETE,
        &format!("/v8/management/plugins/{id}"),
        None,
        PLUGIN_TIMEOUT,
    )
    .await
}

#[tauri::command]
pub async fn plugins_set_enabled(
    state: State<'_, AppState>,
    id: String,
    enabled: bool,
) -> Result<Value, String> {
    if !valid_id(&id) {
        return Err("invalid plugin id".to_string());
    }
    request(
        state.inner(),
        reqwest::Method::PATCH,
        &format!("/v0/management/plugins/{id}/enabled"),
        Some(json!({ "enabled": enabled })),
        PLUGIN_TIMEOUT,
    )
    .await
}

#[tauri::command]
pub async fn plugins_config(state: State<'_, AppState>, id: String) -> Result<Value, String> {
    if !valid_id(&id) {
        return Err("invalid plugin id".to_string());
    }
    request(
        state.inner(),
        reqwest::Method::GET,
        &format!("/v0/management/plugins/{id}/config"),
        None,
        PLUGIN_TIMEOUT,
    )
    .await
}

#[tauri::command]
pub async fn plugins_save_config(
    state: State<'_, AppState>,
    id: String,
    config: Value,
    enabled: bool,
) -> Result<Value, String> {
    if !valid_id(&id) {
        return Err("invalid plugin id".to_string());
    }
    if !config.is_object() {
        return Err("plugin config must be a JSON object".to_string());
    }
    request(
        state.inner(),
        reqwest::Method::PUT,
        &format!("/v0/management/plugins/{id}/config"),
        Some(config),
        PLUGIN_TIMEOUT,
    )
    .await?;
    // PUT persists only. PATCH on the same plugin asks the engine to rebuild
    // the plugin with the saved object, without restarting the whole gateway.
    request(
        state.inner(),
        reqwest::Method::PATCH,
        &format!("/v0/management/plugins/{id}/enabled"),
        Some(json!({ "enabled": enabled })),
        PLUGIN_TIMEOUT,
    )
    .await
}

fn prefs_json() -> Value {
    let prefs = plugin_settings::load();
    json!({
        "hostEnabled": prefs.host_enabled,
        "registryUrl": prefs.registry_url,
        "pluginsDir": plugin_settings::plugins_dir().to_string_lossy(),
    })
}

#[tauri::command]
pub async fn plugins_prefs() -> Result<Value, String> {
    plugin_settings::ensure_plugins_dir()?;
    Ok(prefs_json())
}

#[tauri::command]
pub async fn plugins_set_host(state: State<'_, AppState>, enabled: bool) -> Result<Value, String> {
    let previous = plugin_settings::load();
    let mut prefs = previous.clone();
    prefs.host_enabled = enabled;
    plugin_settings::save(&prefs)?;
    plugin_settings::ensure_plugins_dir()?;
    if let Err(error) = gateway::write_config_current(|| state.settings()) {
        // The pref and the gateway config must not disagree about whether
        // native code is allowed. Restore the old value before returning.
        plugin_settings::save(&previous)?;
        return Err(error);
    }
    let settings = state.settings();
    if gateway::health(settings.port, &settings.api_key).await {
        crate::stop_gateway(state.inner()).await?;
        crate::start_gateway(state.inner()).await?;
    }
    Ok(prefs_json())
}

#[tauri::command]
pub async fn plugins_restart(state: State<'_, AppState>) -> Result<Value, String> {
    let settings = state.settings();
    if !gateway::health(settings.port, &settings.api_key).await {
        return Err("the gateway is not running".to_string());
    }
    crate::stop_gateway(state.inner()).await?;
    crate::start_gateway(state.inner()).await?;
    Ok(json!({ "restarted": true }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plugin_ids_cannot_escape_the_path() {
        assert!(valid_id("jshandler"));
        assert!(valid_id("codex-token-usage"));
        assert!(valid_id("source-abc123"));
        assert!(!valid_id("../etc/passwd"));
        assert!(!valid_id("a/b"));
        assert!(!valid_id(""));
        assert!(!valid_id("-leading"));
        assert!(!valid_id("a?b"));
    }

    #[test]
    fn versions_are_restricted_to_the_engine_alphabet() {
        assert!(valid_version("1.1.0"));
        assert!(valid_version("0.1.45+build.2"));
        assert!(!valid_version("v1.1.0"));
        assert!(!valid_version("1.0/../../x"));
    }

    #[test]
    fn registry_source_is_percent_encoded() {
        assert_eq!(encode_component("source-abc_1"), "source-abc_1");
        assert_eq!(encode_component("a b"), "a%20b");
    }
}
