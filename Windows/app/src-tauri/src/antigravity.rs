//! Antigravity (Google account OAuth) provider: engine-managed login,
//! credential listing/refresh, the model list and the auth-file helpers used
//! by the Providers card.
//!
//! The engine (CLIProxyAPI) runs the OAuth flow and stores the account as
//! `antigravity.json` or `antigravity-<email>.json` in the gateway auth dir,
//! where it hot-reloads it. There is no quota endpoint for Antigravity, so the
//! app only reports identity and the number of models the gateway serves —
//! never percentages.
//!
//! Model ownership is read from the `/v1/models` entry (`owned_by`/`type`);
//! when the response carries no ownership field the engine registry's
//! Antigravity id list is the documented fallback.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::paths;
use crate::settings::Settings;

/// Antigravity ids from the engine registry. Used only when `/v1/models`
/// carries no ownership field.
pub const ANTIGRAVITY_MODEL_IDS: &[&str] = &[
    "claude-opus-4-6-thinking",
    "claude-sonnet-4-6",
    "claude-opus-5-5-high",
    "claude-sonnet-5-5-high",
    "gemini-4-argon-high",
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-low",
    "gemini-3.8-flash-medium",
    "gemini-2.5-pro",
    "gemini-3-flash",
    "gemini-3.1-flash-image",
    "gpt-oss-120b-medium",
    "gemini-3.1-flash-lite",
    "gemini-3.5-flash-lite",
];

// MARK: - Auth files

/// `antigravity.json` or `antigravity-<email>.json`. Everything else — above
/// all `codex-*.json` and `claude-*.json` — is owned by another provider.
pub fn is_antigravity_auth_file_name(name: &str) -> bool {
    name == "antigravity.json" || (name.starts_with("antigravity-") && name.ends_with(".json"))
}

pub fn is_antigravity_model_id(id: &str) -> bool {
    ANTIGRAVITY_MODEL_IDS
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(id))
}

#[derive(Debug, Clone, PartialEq)]
pub struct AuthFile {
    pub name: String,
    pub path: PathBuf,
    pub email: Option<String>,
    pub project_id: Option<String>,
    pub access_token: Option<String>,
    /// Last modification time: the newest file is the account that was just
    /// connected.
    pub modified: Option<std::time::SystemTime>,
}

/// Tolerant decode of an engine-written auth file: field spellings vary
/// between engine versions, so every field is optional; `type` is enforced
/// only when the file carries one.
pub fn decode_auth_file(name: &str, path: &Path, data: &str) -> Option<AuthFile> {
    let root: Value = serde_json::from_str(data).ok()?;
    if let Some(kind) = root.get("type").and_then(|v| v.as_str()) {
        if kind != "antigravity" {
            return None;
        }
    }
    let project_id = ["project_id", "projectId"]
        .iter()
        .find_map(|key| root.get(key).and_then(|v| v.as_str()))
        .filter(|value| !value.is_empty())
        .map(String::from);
    Some(AuthFile {
        name: name.to_string(),
        path: path.to_path_buf(),
        email: root.get("email").and_then(|v| v.as_str()).map(String::from),
        project_id,
        access_token: root
            .get("access_token")
            .and_then(|v| v.as_str())
            .map(String::from),
        modified: None,
    })
}

/// Every Antigravity auth file in `dir`, sorted by name (stable first
/// account).
pub fn auth_files_in(dir: &Path) -> Vec<AuthFile> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<AuthFile> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !is_antigravity_auth_file_name(&name) {
            continue;
        }
        let path = entry.path();
        let Ok(data) = std::fs::read_to_string(&path) else {
            continue;
        };
        if let Some(mut file) = decode_auth_file(&name, &path, &data) {
            file.modified = entry.metadata().and_then(|m| m.modified()).ok();
            files.push(file);
        }
    }
    files.sort_by(|a, b| a.name.cmp(&b.name));
    files
}

/// The "current account" file: the most recently modified one (the account
/// that was just connected). Ties fall back to the name so the choice stays
/// deterministic.
pub fn newest_of(files: &[AuthFile]) -> Option<AuthFile> {
    files
        .iter()
        .max_by(|a, b| {
            a.modified
                .cmp(&b.modified)
                .then_with(|| a.name.cmp(&b.name))
        })
        .cloned()
}

pub fn newest_auth_file_in(dir: &Path) -> Option<AuthFile> {
    newest_of(&auth_files_in(dir))
}

/// Auth files in the live gateway auth dir.
#[allow(dead_code)]
pub fn auth_files() -> Vec<AuthFile> {
    auth_files_in(&paths::auths_dir())
}

/// The newest auth file in the live gateway auth dir.
#[allow(dead_code)]
pub fn newest_auth_file() -> Option<AuthFile> {
    newest_auth_file_in(&paths::auths_dir())
}

/// Removes one account file, leaving the rest of the pool untouched.
pub fn remove_auth_file(name: &str) -> bool {
    if !is_antigravity_auth_file_name(name) {
        return false;
    }
    std::fs::remove_file(paths::auths_dir().join(name)).is_ok()
}

/// Removes only Antigravity auth files from `dir`; returns
/// `(removed, remaining_antigravity_files)`.
pub fn disconnect_in(dir: &Path) -> (usize, usize) {
    let mut removed = 0usize;
    for file in auth_files_in(dir) {
        if std::fs::remove_file(&file.path).is_ok() {
            removed += 1;
        }
    }
    (removed, auth_files_in(dir).len())
}

// MARK: - Model ownership

fn ownership_text<'a>(entry: &'a Value, key: &str) -> Option<&'a str> {
    entry
        .get(key)
        .and_then(|value| value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

/// Whether a `/v1/models` entry is served by Antigravity. `owned_by` and
/// `type` are both checked because engine versions spell the marker
/// differently. When neither field is present the registry id allowlist is
/// the fallback.
pub fn is_antigravity_model_entry(entry: &Value) -> bool {
    let mut saw_ownership = false;
    for key in ["owned_by", "owner", "type"] {
        if let Some(owner) = ownership_text(entry, key) {
            saw_ownership = true;
            if owner.eq_ignore_ascii_case("antigravity") {
                return true;
            }
        }
    }
    if saw_ownership {
        return false;
    }
    entry
        .get("id")
        .and_then(|value| value.as_str())
        .map(is_antigravity_model_id)
        .unwrap_or(false)
}

fn display_name(entry: &Value, id: &str) -> String {
    ["display_name", "displayName", "name"]
        .iter()
        .find_map(|key| ownership_text(entry, key))
        .map(String::from)
        .unwrap_or_else(|| crate::codex_route::prettify(id))
}

fn model_entries<F>(root: &Value, include: F) -> Vec<Value>
where
    F: Fn(&Value, &str) -> bool,
{
    root.get("data")
        .and_then(|value| value.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let id = item.get("id").and_then(|value| value.as_str())?;
                    if !include(item, id) {
                        return None;
                    }
                    Some(json!({ "id": id, "displayName": display_name(item, id) }))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Antigravity-owned entries of a `/v1/models` payload.
pub fn parse_models(root: &Value) -> Vec<Value> {
    model_entries(root, |entry, _id| is_antigravity_model_entry(entry))
}

/// Claude entries of a `/v1/models` payload, excluding ids the engine marks as
/// Antigravity-owned. Antigravity also serves `claude-*` ids, so the plain
/// prefix filter is not enough.
pub fn parse_claude_models(root: &Value) -> Vec<Value> {
    model_entries(root, |entry, id| {
        crate::claude::is_claude_model_id(id) && !is_antigravity_model_entry(entry)
    })
}

async fn fetch_models(port: u16, api_key: &str) -> Result<Value, String> {
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    response.json().await.map_err(|e| e.to_string())
}

/// Antigravity model ids served by the running gateway.
pub async fn models(port: u16, api_key: &str) -> Result<Value, String> {
    let root = fetch_models(port, api_key).await?;
    let entries = parse_models(&root);
    Ok(json!({ "models": entries.clone(), "count": entries.len() }))
}

/// Claude model ids served by the gateway, with Antigravity-owned ids removed.
/// Replaces `claude::models` for the app's listing and metrics so the Claude
/// provider never claims Antigravity's Claude models.
pub async fn claude_models_without_antigravity(port: u16, api_key: &str) -> Result<Value, String> {
    let root = fetch_models(port, api_key).await?;
    let entries = parse_claude_models(&root);
    Ok(json!({ "models": entries.clone(), "count": entries.len() }))
}

// MARK: - Management client

pub struct Management {
    port: u16,
    secret: String,
    client: reqwest::Client,
}

impl Management {
    pub fn new(settings: &Settings) -> Result<Self, String> {
        let client = crate::proxy::apply(reqwest::Client::builder())
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Self {
            port: settings.port,
            secret: settings.management_secret.clone(),
            client,
        })
    }

    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        // The engine accepts either header; both are sent so the app is robust
        // against middleware variants.
        self.client
            .request(method, format!("http://127.0.0.1:{}{}", self.port, path))
            .header("Authorization", format!("Bearer {}", self.secret))
            .header("X-Management-Key", self.secret.clone())
            .header("Accept", "application/json")
    }

    async fn call(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<(u16, String), String> {
        let mut request = self.request(method, path);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        let text = response.text().await.map_err(|e| e.to_string())?;
        Ok((status, text))
    }

    fn body_json(text: &str) -> Value {
        serde_json::from_str(text).unwrap_or(Value::Null)
    }

    /// `GET /v8/management/oauth/auth-url?provider=antigravity&is_webui=true`.
    /// `is_webui=true` is required: it starts the engine callback forwarder
    /// on port 51121 that receives the Google redirect.
    pub async fn login_start(&self) -> Result<Value, String> {
        let (status, text) = self
            .call(
                reqwest::Method::GET,
                "/v8/management/oauth/auth-url?provider=antigravity&is_webui=true",
                None,
            )
            .await
            .map_err(|_| "шлюз не отвечает — запустите его и повторите".to_string())?;
        let body = Self::body_json(&text);
        if status != 200 {
            return Err(format!("шлюз отклонил вход ({})", status));
        }
        let (url, state) = crate::claude::parse_auth_url(&body)
            .ok_or_else(|| "шлюз не вернул ссылку входа".to_string())?;
        Ok(json!({ "url": url, "state": state }))
    }

    /// `GET /v8/management/oauth/status?state=…` → `ok` | `wait` | `error`.
    pub async fn login_status(&self, state: &str) -> Result<Value, String> {
        let (status, text) = self
            .call(
                reqwest::Method::GET,
                &format!(
                    "/v8/management/oauth/status?state={}",
                    crate::claude::url_query(state)
                ),
                None,
            )
            .await?;
        if status != 200 {
            return Err(format!("шлюз отклонил запрос статуса ({})", status));
        }
        let value = Self::body_json(&text);
        let state_name = crate::claude::parse_status(&value)
            .ok_or_else(|| "шлюз не вернул статус входа".to_string())?;
        Ok(json!({ "status": state_name }))
    }

    /// `DELETE /v8/management/oauth/session?state=…` — drops a pending login.
    pub async fn login_cancel(&self, state: &str) -> Result<Value, String> {
        let (status, _) = self
            .call(
                reqwest::Method::DELETE,
                &format!(
                    "/v8/management/oauth/session?state={}",
                    crate::claude::url_query(state)
                ),
                None,
            )
            .await?;
        Ok(json!({ "canceled": (200..300).contains(&status) }))
    }

    /// `GET /v8/management/credentials`, filtered to Antigravity accounts.
    pub async fn credentials(&self) -> Result<Value, String> {
        let (status, text) = self
            .call(reqwest::Method::GET, "/v8/management/credentials", None)
            .await?;
        if status != 200 {
            return Ok(json!({ "credentials": [] }));
        }
        let parsed = crate::claude::parse_credentials(&Self::body_json(&text));
        Ok(json!({ "credentials": filter_credentials(parsed) }))
    }

    /// Refreshes one credential file (`{"name": …}`) or all of them
    /// (`?all=true`) when no name is given. Failures are reported as
    /// `ok: false` — a refresh must not break the card.
    pub async fn refresh(&self, name: Option<&str>) -> Value {
        let (path, body) = match name.filter(|n| !n.is_empty()) {
            Some(name) => (
                "/v8/management/credentials/refresh".to_string(),
                Some(json!({ "name": name })),
            ),
            None => (
                "/v8/management/credentials/refresh?all=true".to_string(),
                None,
            ),
        };
        match self.call(reqwest::Method::POST, &path, body).await {
            Ok((status, _)) => json!({ "ok": (200..300).contains(&status) }),
            Err(_) => json!({ "ok": false }),
        }
    }
}

/// Keeps only credential entries that belong to Antigravity: the engine may
/// omit `type`, so the file-name predicate is checked as well.
pub fn filter_credentials(entries: Vec<Value>) -> Vec<Value> {
    entries
        .into_iter()
        .filter(|entry| {
            let by_type = entry
                .get("type")
                .and_then(|value| value.as_str())
                .map(|value| value.eq_ignore_ascii_case("antigravity"))
                .unwrap_or(false);
            let by_name = entry
                .get("name")
                .and_then(|value| value.as_str())
                .map(is_antigravity_auth_file_name)
                .unwrap_or(false);
            by_type || by_name
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "melon-antigravity-test-{}-{}",
            std::process::id(),
            tag
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    fn fixture_entry(id: &str, owned_by: Option<&str>, kind: Option<&str>) -> Value {
        let mut entry = json!({"id": id, "object": "model"});
        if let Some(owned_by) = owned_by {
            entry["owned_by"] = json!(owned_by);
        }
        if let Some(kind) = kind {
            entry["type"] = json!(kind);
        }
        entry
    }

    #[test]
    fn probe_targets_prefer_the_list_and_fall_back_to_the_single_model() {
        assert_eq!(
            probe_targets(Some(vec!["a".into(), "b".into()]), Some("legacy".into())),
            vec!["a".to_string(), "b".to_string()]
        );
        assert_eq!(
            probe_targets(Some(Vec::new()), Some("legacy".into())),
            vec!["legacy".to_string()]
        );
        assert_eq!(
            probe_targets(None, Some("legacy".into())),
            vec!["legacy".to_string()]
        );
        assert!(probe_targets(None, None).is_empty());
    }

    #[test]
    fn auth_file_predicates_own_only_antigravity_files() {
        assert!(is_antigravity_auth_file_name("antigravity.json"));
        assert!(is_antigravity_auth_file_name(
            "antigravity-1a2b3c4d-user@example.com.json"
        ));
        assert!(!is_antigravity_auth_file_name(
            "claude-user@example.com.json"
        ));
        assert!(!is_antigravity_auth_file_name(
            "codex-user@example.com.json"
        ));
        assert!(!is_antigravity_auth_file_name(
            "._antigravity-user@example.com.json"
        ));
        assert!(!is_antigravity_auth_file_name("antigravity-user.json.bak"));
        assert!(is_antigravity_model_id("gemini-3-flash"));
        assert!(is_antigravity_model_id("claude-opus-4-6-thinking"));
        assert!(is_antigravity_model_id("gemini-3.8-flash-medium"));
        assert!(is_antigravity_model_id("gemini-2.5-pro"));
        assert!(!is_antigravity_model_id("claude-opus-5-5"));
    }

    #[test]
    fn auth_files_in_reads_only_antigravity_files_and_sorts_them() {
        let dir = temp_dir("authfiles");
        fs::write(
            dir.join("claude-user@example.com.json"),
            r#"{"type":"claude","email":"claude@example.com"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("antigravity-zzzz1111-second@example.com.json"),
            r#"{"type":"antigravity","email":"second@example.com","project_id":"project-2","access_token":"token-2"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("antigravity-aaaa0000-first@example.com.json"),
            r#"{"type":"antigravity","email":"first@example.com","projectId":"project-1","access_token":"token-1"}"#,
        )
        .unwrap();
        fs::write(dir.join("notes.txt"), "not an auth file").unwrap();

        let files = auth_files_in(&dir);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].email.as_deref(), Some("first@example.com"));
        assert_eq!(files[0].project_id.as_deref(), Some("project-1"));
        assert_eq!(files[0].access_token.as_deref(), Some("token-1"));
        assert_eq!(files[1].email.as_deref(), Some("second@example.com"));
        assert_eq!(files[1].project_id.as_deref(), Some("project-2"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn decode_auth_file_tolerates_missing_fields_and_rejects_other_types() {
        let path = PathBuf::from("/tmp/antigravity-x.json");
        let decoded = decode_auth_file("antigravity.json", &path, r#"{"email":"a@b.c"}"#)
            .expect("no type field is accepted");
        assert_eq!(decoded.email.as_deref(), Some("a@b.c"));
        assert!(decoded.project_id.is_none());
        assert!(decoded.access_token.is_none());
        assert!(decode_auth_file("antigravity.json", &path, r#"{"type":"antigravity"}"#).is_some());
        assert!(decode_auth_file("antigravity.json", &path, r#"{"type":"claude"}"#).is_none());
        assert!(decode_auth_file("antigravity.json", &path, "{not json").is_none());
    }

    #[test]
    fn newest_of_picks_the_most_recently_modified_file() {
        let base = std::time::SystemTime::UNIX_EPOCH;
        let older = AuthFile {
            name: "antigravity-aaaa0000-old@example.com.json".to_string(),
            path: PathBuf::from("/x/older.json"),
            email: Some("old@example.com".to_string()),
            project_id: None,
            access_token: None,
            modified: Some(base),
        };
        let newer = AuthFile {
            name: "antigravity-zzzz9999-new@example.com.json".to_string(),
            path: PathBuf::from("/x/newer.json"),
            email: Some("new@example.com".to_string()),
            project_id: Some("project-new".to_string()),
            access_token: None,
            modified: Some(base + Duration::from_secs(60)),
        };
        let picked = newest_of(&[older.clone(), newer.clone()]).unwrap();
        assert_eq!(picked.email.as_deref(), Some("new@example.com"));
        assert_eq!(picked.project_id.as_deref(), Some("project-new"));

        // Without usable timestamps the name decides, deterministically.
        let mut a = older;
        a.modified = None;
        let mut b = newer;
        b.modified = None;
        assert_eq!(
            newest_of(&[a, b]).unwrap().name,
            "antigravity-zzzz9999-new@example.com.json"
        );
        assert!(newest_of(&[]).is_none());
    }

    #[test]
    fn newest_auth_file_in_follows_the_modification_time() {
        let dir = temp_dir("newest");
        let old_path = dir.join("antigravity-aaaa0000-old@example.com.json");
        fs::write(
            &old_path,
            r#"{"type":"antigravity","email":"old@example.com","project_id":"p-old"}"#,
        )
        .unwrap();
        let new_path = dir.join("antigravity-zzzz9999-new@example.com.json");
        fs::write(
            &new_path,
            r#"{"type":"antigravity","email":"new@example.com","project_id":"p-new"}"#,
        )
        .unwrap();

        // Set explicit timestamps so the ordering does not depend on the
        // filesystem's timestamp resolution.
        let old_time = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_600_000_000);
        let new_time = old_time + Duration::from_secs(60);
        fs::File::options()
            .write(true)
            .open(&old_path)
            .unwrap()
            .set_modified(old_time)
            .unwrap();
        fs::File::options()
            .write(true)
            .open(&new_path)
            .unwrap()
            .set_modified(new_time)
            .unwrap();

        let newest = newest_auth_file_in(&dir).expect("an antigravity auth file");
        assert_eq!(newest.email.as_deref(), Some("new@example.com"));
        assert_eq!(newest.project_id.as_deref(), Some("p-new"));
        assert!(newest.modified.is_some());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn disconnect_removes_only_antigravity_files() {
        let dir = temp_dir("disconnect");
        fs::write(
            dir.join("antigravity-a@example.com.json"),
            r#"{"type":"antigravity","email":"a@example.com"}"#,
        )
        .unwrap();
        fs::write(
            dir.join("antigravity-b@example.com.json"),
            r#"{"type":"antigravity","email":"b@example.com"}"#,
        )
        .unwrap();
        let claude = dir.join("claude-a@example.com.json");
        let codex = dir.join("codex-a@example.com.json");
        fs::write(&claude, r#"{"type":"claude"}"#).unwrap();
        fs::write(&codex, r#"{"type":"codex"}"#).unwrap();

        let (removed, remaining) = disconnect_in(&dir);
        assert_eq!(removed, 2);
        assert_eq!(remaining, 0);
        assert!(claude.exists());
        assert!(codex.exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn model_filter_prefers_ownership_and_falls_back_to_the_allowlist() {
        let root = json!({
            "data": [
                fixture_entry("claude-opus-4-6-thinking", Some("antigravity"), Some("antigravity")),
                fixture_entry("claude-sonnet-4-6", Some("anthropic"), Some("claude")),
                fixture_entry("claude-opus-5-5", Some("anthropic"), Some("claude")),
                fixture_entry("gemini-3-flash", Some("antigravity"), Some("antigravity")),
                // No ownership field: the registry allowlist decides.
                fixture_entry("gemini-3.1-flash-lite", None, None),
                fixture_entry("gpt-6.1-sol", None, None)
            ]
        });

        let antigravity: Vec<String> = parse_models(&root)
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            antigravity,
            vec![
                "claude-opus-4-6-thinking",
                "gemini-3-flash",
                "gemini-3.1-flash-lite"
            ]
        );

        let claude: Vec<String> = parse_claude_models(&root)
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(claude, vec!["claude-sonnet-4-6", "claude-opus-5-5"]);
    }

    #[test]
    fn model_filter_without_ownership_data_uses_the_allowlist_for_both_views() {
        let root = json!({
            "data": [
                {"id": "claude-opus-4-6-thinking"},
                {"id": "claude-sonnet-4-6"},
                {"id": "claude-opus-5-5"},
                {"id": "gemini-3-flash"}
            ]
        });

        let antigravity: Vec<String> = parse_models(&root)
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            antigravity,
            vec![
                "claude-opus-4-6-thinking",
                "claude-sonnet-4-6",
                "gemini-3-flash"
            ]
        );

        // The overlapping Claude ids must not be claimed by the Claude view
        // when ownership is unavailable.
        let claude: Vec<String> = parse_claude_models(&root)
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(claude, vec!["claude-opus-5-5"]);
    }

    #[test]
    fn antigravity_model_entries_keep_registry_display_names() {
        let root = json!({
            "data": [
                {
                    "id": "gemini-3.8-flash-high",
                    "owned_by": "antigravity",
                    "display_name": "Gemini 3.8 Flash",
                    "name": "gemini-3.8-flash-high"
                },
                {"id": "gemini-3-flash", "type": "antigravity"}
            ]
        });
        let entries = parse_models(&root);
        assert_eq!(entries[0]["displayName"], "Gemini 3.8 Flash");
        assert_eq!(entries[1]["displayName"], "Gemini 3 Flash");
    }

    #[test]
    fn credentials_filter_keeps_only_antigravity_entries() {
        let entries = vec![
            json!({"name": "antigravity-a@example.com.json", "type": "antigravity"}),
            json!({"name": "claude-a@example.com.json", "type": "claude"}),
            // The engine may omit type; the file name still identifies it.
            json!({"name": "antigravity.json"}),
            json!({"name": "codex-a.json", "type": "codex"}),
        ];
        let filtered = filter_credentials(entries);
        assert_eq!(filtered.len(), 2);
        assert_eq!(filtered[0]["name"], "antigravity-a@example.com.json");
        assert_eq!(filtered[1]["name"], "antigravity.json");
    }
}

// MARK: - Pool projection

impl Management {
    /// `GET /v0/management/auth-files`: every account the engine loaded, with
    /// cooldowns and priority.
    pub async fn auth_files(&self) -> Result<Value, String> {
        let (status, text) = self
            .call(reqwest::Method::GET, "/v0/management/auth-files", None)
            .await?;
        if status != 200 {
            return Err(format!("auth-files ({status})"));
        }
        Ok(Self::body_json(&text))
    }

    /// `GET /v0/management/auth-files/models?name=…`: models registered for
    /// one auth file.
    pub async fn auth_models(&self, name: &str) -> Vec<String> {
        let path = format!(
            "/v0/management/auth-files/models?name={}",
            crate::claude::url_query(name)
        );
        let Ok((status, text)) = self.call(reqwest::Method::GET, &path, None).await else {
            return Vec::new();
        };
        if status != 200 {
            return Vec::new();
        }
        let body = Self::body_json(&text);
        body.get("models")
            .and_then(|value| value.as_array())
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("id").and_then(|value| value.as_str()))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default()
    }

    pub async fn set_disabled(&self, name: &str, auth_index: Option<&str>, disabled: bool) -> bool {
        let mut body = json!({ "name": name, "disabled": disabled });
        if let Some(index) = auth_index.filter(|value| !value.is_empty()) {
            body["auth_index"] = json!(index);
        }
        matches!(
            self.call(
                reqwest::Method::PATCH,
                "/v0/management/auth-files/status",
                Some(body)
            )
            .await,
            Ok((status, _)) if (200..300).contains(&status)
        )
    }

    pub async fn set_priority(&self, name: &str, priority: i64) -> bool {
        matches!(
            self.call(
                reqwest::Method::PATCH,
                "/v0/management/auth-files/fields",
                Some(json!({ "name": name, "priority": priority }))
            )
            .await,
            Ok((status, _)) if (200..300).contains(&status)
        )
    }

    pub async fn clear_bootstrap_cooldown(&self, auth_index: &str, model: &str) -> bool {
        if model.is_empty() {
            return false;
        }
        matches!(
            self.call(
                reqwest::Method::POST,
                "/v0/management/routing/bootstrap-cooldown/reset",
                Some(json!({ "auth_index": auth_index, "model": model }))
            )
            .await,
            Ok((status, _)) if (200..300).contains(&status)
        )
    }
}

/// Models a probe must release. `models` is the current UI payload (every
/// watchdog cooldown of the account); the single `model` is the pre-4.0.1
/// shape and stays accepted for older WebView bundles.
pub fn probe_targets(models: Option<Vec<String>>, model: Option<String>) -> Vec<String> {
    match models {
        Some(list) if !list.is_empty() => list,
        _ => model.into_iter().collect(),
    }
}

/// Lightweight health probe for a quarantined account: a model-list request
/// must succeed before every first-token cooldown of the account is released.
pub async fn probe_account(
    settings: &Settings,
    name: &str,
    auth_index: &str,
    models: &[String],
) -> bool {
    if models.is_empty() || auth_index.is_empty() {
        return false;
    }
    let Some(file) = auth_files_in(&paths::auths_dir())
        .into_iter()
        .find(|candidate| candidate.name == name)
    else {
        return false;
    };
    let Some(token) = file.access_token.as_deref() else {
        return false;
    };
    let Ok(client) = crate::proxy::apply(reqwest::Client::builder())
        .timeout(Duration::from_secs(15))
        .build()
    else {
        return false;
    };
    if request_quota(
        &client,
        token,
        file.project_id.as_deref().unwrap_or_default(),
    )
    .await
    .is_none()
    {
        return false;
    }
    let Ok(manager) = Management::new(settings) else {
        return false;
    };
    let mut cleared_all = true;
    for model in models {
        if !manager.clear_bootstrap_cooldown(auth_index, model).await {
            cleared_all = false;
        }
    }
    cleared_all
}

/// A per-account quota pool from `quotaInfo`. Gemini models share one window;
/// the Anthropic/OpenAI models share the other.
fn quota_window(models: &serde_json::Map<String, Value>, google: bool) -> Option<Value> {
    let mut remaining = f64::MAX;
    let mut reset = String::new();
    let mut ids: Vec<String> = Vec::new();
    for (id, raw) in models {
        let Some(entry) = raw.as_object() else {
            continue;
        };
        let provider = entry
            .get("modelProvider")
            .and_then(|value| value.as_str())
            .unwrap_or("");
        if (provider == "MODEL_PROVIDER_GOOGLE") != google {
            continue;
        }
        let Some(quota) = entry.get("quotaInfo").and_then(|value| value.as_object()) else {
            continue;
        };
        let Some(fraction) = quota
            .get("remainingFraction")
            .and_then(|value| value.as_f64())
        else {
            continue;
        };
        remaining = remaining.min(fraction);
        if reset.is_empty() {
            if let Some(stamp) = quota.get("resetTime").and_then(|value| value.as_str()) {
                reset = stamp.to_string();
            }
        }
        ids.push(id.clone());
    }
    if remaining == f64::MAX {
        return None;
    }
    Some(json!({
        "remaining": remaining,
        "resetAt": if reset.is_empty() { Value::Null } else { json!(reset) },
        "modelIds": ids,
    }))
}

async fn fetch_quota(settings: &Settings, file: &AuthFile) -> Value {
    let Some(token) = file.access_token.clone() else {
        return json!({ "error": "Войдите заново, чтобы прочитать квоту." });
    };
    let client = match crate::proxy::apply(reqwest::Client::builder())
        .timeout(Duration::from_secs(20))
        .build()
    {
        Ok(client) => client,
        Err(error) => return json!({ "error": error.to_string() }),
    };
    let project = file.project_id.clone().unwrap_or_default();
    let quota = request_quota(&client, &token, &project).await;
    match quota {
        Some(value) => value,
        None => {
            // A stale access token is the common failure. Refresh through the
            // engine and retry once with the token it wrote back.
            if let Ok(management) = Management::new(settings) {
                let _ = management.refresh(Some(&file.name)).await;
            }
            if let Some(refreshed) = auth_files_in(&paths::auths_dir())
                .into_iter()
                .find(|candidate| candidate.name == file.name)
            {
                if refreshed.access_token.as_deref() != Some(token.as_str()) {
                    if let Some(value) = request_quota(
                        &client,
                        refreshed.access_token.as_deref().unwrap_or_default(),
                        refreshed.project_id.as_deref().unwrap_or_default(),
                    )
                    .await
                    {
                        return value;
                    }
                }
            }
            json!({ "error": "Квота сейчас недоступна." })
        }
    }
}

async fn request_quota(client: &reqwest::Client, token: &str, project: &str) -> Option<Value> {
    let response = client
        .post("https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
        .bearer_auth(token)
        .header("Content-Type", "application/json")
        .header(
            "User-Agent",
            "antigravity/hub/2.24.0 (aidev_client; os_type=windows; arch=amd64)",
        )
        .json(&json!({ "project": project }))
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body: Value = response.json().await.ok()?;
    let models = body.get("models")?.as_object()?;
    let gemini = quota_window(models, true);
    let claude = quota_window(models, false);
    if gemini.is_none() && claude.is_none() {
        return None;
    }
    Some(json!({ "gemini": gemini, "claude": claude }))
}

/// Catalog entries the connected accounts cannot use. The catalog file is the
/// same one the app writes for the engine; a missing file simply hides the
/// section.
fn catalog_only(entitled: &std::collections::HashSet<String>) -> Vec<Value> {
    let Ok(data) = std::fs::read_to_string(crate::catalog::catalog_path()) else {
        return Vec::new();
    };
    let Ok(root) = serde_json::from_str::<Value>(&data) else {
        return Vec::new();
    };
    let Some(entries) = root.get("antigravity").and_then(|value| value.as_array()) else {
        return Vec::new();
    };
    let mut result: Vec<Value> = entries
        .iter()
        .filter_map(|entry| {
            let id = entry.get("id")?.as_str()?;
            if entitled.contains(id) {
                return None;
            }
            let display = entry
                .get("display_name")
                .and_then(|value| value.as_str())
                .unwrap_or(id);
            Some(json!({ "id": id, "displayName": display }))
        })
        .collect();
    result.sort_by(|left, right| {
        left["displayName"]
            .as_str()
            .unwrap_or("")
            .cmp(right["displayName"].as_str().unwrap_or(""))
    });
    result
}

/// Full pool snapshot for the Providers card: one entry per auth file with
/// identity, models, cooldowns and both quota windows.
pub async fn account_views(settings: &Settings) -> Value {
    let files = auth_files_in(&paths::auths_dir());
    let management = Management::new(settings).ok();
    let snapshot = match &management {
        Some(manager) => manager.auth_files().await.unwrap_or(Value::Null),
        None => Value::Null,
    };
    let entries = snapshot
        .get("files")
        .and_then(|value| value.as_array())
        .cloned()
        .unwrap_or_default();

    let mut accounts: Vec<Value> = Vec::new();
    let mut entitled = std::collections::HashSet::new();
    for file in &files {
        let entry = entries.iter().find(|item| {
            item.get("name").and_then(|value| value.as_str()) == Some(file.name.as_str())
        });
        let mut models = match &management {
            Some(manager) => manager.auth_models(&file.name).await,
            None => Vec::new(),
        };
        let quota = fetch_quota(settings, file).await;
        // The per-auth models endpoint can be empty for a moment while the
        // engine registers a freshly loaded account. The quota response carries
        // the same ids, so use it as a fallback instead of showing zero models.
        if models.is_empty() {
            for pool in ["gemini", "claude"] {
                if let Some(ids) = quota
                    .get(pool)
                    .and_then(|value| value.get("modelIds"))
                    .and_then(|value| value.as_array())
                {
                    for id in ids.iter().filter_map(|value| value.as_str()) {
                        if !models.iter().any(|model| model == id) {
                            models.push(id.to_string());
                        }
                    }
                }
            }
        }
        for model in &models {
            entitled.insert(model.clone());
        }
        accounts.push(json!({
            "name": file.name,
            "email": file.email,
            "projectId": file.project_id,
            "authIndex": entry.and_then(|item| item.get("auth_index")).and_then(|value| value.as_str()),
            "priority": entry.and_then(|item| item.get("priority")).and_then(|value| value.as_i64()).unwrap_or(0),
            "disabled": entry.and_then(|item| item.get("disabled")).and_then(|value| value.as_bool()).unwrap_or(false),
            "status": entry.and_then(|item| item.get("status")).and_then(|value| value.as_str()),
            "statusMessage": entry.and_then(|item| item.get("status_message")).and_then(|value| value.as_str()),
            "unavailable": entry.and_then(|item| item.get("unavailable")).and_then(|value| value.as_bool()).unwrap_or(false),
            "cooldowns": entry.and_then(|item| item.get("cooldowns")).cloned().unwrap_or(Value::Null),
            "models": models,
            "gemini": quota.get("gemini").cloned().unwrap_or(Value::Null),
            "claude": quota.get("claude").cloned().unwrap_or(Value::Null),
            "quotaError": quota.get("error").cloned().unwrap_or(Value::Null),
        }));
    }
    accounts.sort_by(|left, right| {
        let lp = left["priority"].as_i64().unwrap_or(0);
        let rp = right["priority"].as_i64().unwrap_or(0);
        rp.cmp(&lp)
    });
    json!({ "accounts": accounts, "catalogOnly": catalog_only(&entitled) })
}

#[cfg(test)]
mod pool_tests {
    use super::*;

    #[test]
    fn quota_window_groups_google_and_third_party_models() {
        let raw = json!({
            "gemini-a": {"modelProvider": "MODEL_PROVIDER_GOOGLE", "quotaInfo": {"remainingFraction": 0.8, "resetTime": "2026-11-01T16:15:53Z"}},
            "gemini-b": {"modelProvider": "MODEL_PROVIDER_GOOGLE", "quotaInfo": {"remainingFraction": 0.6, "resetTime": "2026-11-01T16:15:53Z"}},
            "claude-a": {"modelProvider": "MODEL_PROVIDER_ANTHROPIC", "quotaInfo": {"remainingFraction": 0.95, "resetTime": "2026-11-01T20:47:28Z"}}
        });
        let models = raw.as_object().unwrap();
        let gemini = quota_window(models, true).unwrap();
        assert!((gemini["remaining"].as_f64().unwrap() - 0.6).abs() < f64::EPSILON);
        assert_eq!(gemini["modelIds"].as_array().unwrap().len(), 2);
        let claude = quota_window(models, false).unwrap();
        assert!((claude["remaining"].as_f64().unwrap() - 0.95).abs() < f64::EPSILON);
        assert_eq!(claude["modelIds"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn quota_window_without_quota_info_is_none() {
        let raw = json!({"m": {"modelProvider": "MODEL_PROVIDER_GOOGLE"}});
        assert!(quota_window(raw.as_object().unwrap(), true).is_none());
    }
}
