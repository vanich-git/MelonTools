//! Official Codex client model list.
//!
//! The local `~/.codex/models_cache.json` is written by the Codex desktop app.
//! Re-reading it is not enough to discover a model OpenAI has just released,
//! so "Load models" asks the same endpoint the Codex client uses.

use serde_json::{json, Map, Value};

use crate::{paths, quota, vault};

const ENDPOINT: &str = "https://chatgpt.com/backend-api/codex/models";
const CLIENT_VERSION: &str = "0.159.0";
const USER_AGENT: &str = "codex_cli_rs/0.159.0 (Mac OS 26.3.1; arm64) iTerm.app/3.6.9";

/// Fetch the catalog with the first usable Codex account and merge it into the
/// Codex cache. The caller then re-reads the pool, exactly like the UI.
pub async fn refresh_models() -> Result<Value, String> {
    let accounts = vault::accounts();
    let account = accounts
        .iter()
        .find(|account| {
            !account.needs_relogin.unwrap_or(false)
                && account
                    .tokens
                    .access_token
                    .as_deref()
                    .map(|token| !token.trim().is_empty())
                    .unwrap_or(false)
        })
        .ok_or_else(|| "добавьте аккаунт Codex, чтобы загрузить модели".to_string())?
        .clone();
    let client = quota::client()?;
    let mut tokens = quota::ensure_fresh(&client, &account).await?;
    let mut response = request(&client, &tokens, &account).await;
    if matches!(&response, Err(error) if error.starts_with("models 401:")) {
        tokens = quota::refresh_tokens(&client, &account).await?;
        vault::update_tokens(&account.id, &tokens, &chrono::Utc::now().to_rfc3339())?;
        response = request(&client, &tokens, &account).await;
    }
    let models = response?;
    let path = merge_cache(&models, chrono::Utc::now())?;
    Ok(json!({
        "count": models.len(),
        "path": path.to_string_lossy(),
        "clientVersion": CLIENT_VERSION,
    }))
}

async fn request(
    client: &reqwest::Client,
    tokens: &vault::Tokens,
    account: &vault::Account,
) -> Result<Vec<Value>, String> {
    let access = tokens
        .access_token
        .as_deref()
        .filter(|token| !token.trim().is_empty())
        .ok_or_else(|| "в аккаунте нет access_token".to_string())?;
    let mut request = client
        .get(ENDPOINT)
        .query(&[("client_version", CLIENT_VERSION)])
        .header("Authorization", format!("Bearer {access}"))
        .header("Accept", "application/json")
        .header("Originator", "codex_cli_rs")
        .header("User-Agent", USER_AGENT);
    if let Some(account_id) = account
        .tokens
        .account_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
    {
        request = request.header("Chatgpt-Account-Id", account_id);
    }
    let response = request.send().await.map_err(|e| e.to_string())?;
    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("models {}: {}", status.as_u16(), text));
    }
    let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let models = value
        .get("models")
        .and_then(Value::as_array)
        .filter(|models| !models.is_empty())
        .ok_or_else(|| "ответ не содержит списка моделей".to_string())?;
    Ok(models.clone())
}

/// Merge the official list into the Codex cache without discarding the
/// identity/etag metadata Codex uses for its own refresh logic.
pub fn merge_cache(
    models: &[Value],
    fetched_at: chrono::DateTime<chrono::Utc>,
) -> Result<std::path::PathBuf, String> {
    let path = paths::codex_home().join("models_cache.json");
    let existing = std::fs::read_to_string(&path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let data = serde_json::to_string(&merge_cache_object(existing, models, fetched_at))
        .map_err(|e| e.to_string())?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = paths::tmp_path(&path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
    Ok(path)
}

/// Pure merge used by [`merge_cache`] and tests. Codex owns `identity`,
/// `etag` and other metadata, so only the model list and fetch stamp change.
pub fn merge_cache_object(
    existing: Option<Value>,
    models: &[Value],
    fetched_at: chrono::DateTime<chrono::Utc>,
) -> Value {
    let mut root: Map<String, Value> = existing
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    root.insert("models".to_string(), json!(models));
    root.insert(
        "fetched_at".to_string(),
        json!(fetched_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
    );
    root.insert("client_version".to_string(), json!(CLIENT_VERSION));
    Value::Object(root)
}

#[cfg(test)]
mod tests {
    use super::merge_cache_object;

    #[test]
    fn merged_cache_replaces_models_and_keeps_metadata() {
        let existing = serde_json::json!({
            "identity": {"email": "user@example.com"},
            "etag": "v1",
            "models": [{"slug": "old"}]
        });
        let models = vec![serde_json::json!({
            "slug": "gpt-6.1-terra",
            "display_name": "GPT-6.1 Terra"
        })];
        let value = merge_cache_object(Some(existing), &models, chrono::Utc::now());
        assert_eq!(value["etag"], "v1");
        assert_eq!(value["identity"]["email"], "user@example.com");
        assert_eq!(value["models"][0]["slug"], "gpt-6.1-terra");
        assert_eq!(value["client_version"], "0.159.0");
    }
}
