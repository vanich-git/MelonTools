//! Import Claude and Antigravity OAuth credentials from Cockpit/CPA and
//! sub2api JSON exports into the engine auth directory.
//!
//! The engine hot-reloads `auths/*.json`, so an import that happens while the
//! gateway is running is picked up without a restart. Files written here are
//! owned by the provider: the Codex account sync only replaces `codex-*.json`
//! and leaves everything else alone.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};

use crate::paths;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderKind {
    Claude,
    Antigravity,
}

impl ProviderKind {
    pub fn type_name(self) -> &'static str {
        match self {
            ProviderKind::Claude => "claude",
            ProviderKind::Antigravity => "antigravity",
        }
    }

    fn is_auth_file(self, name: &str) -> bool {
        match self {
            ProviderKind::Claude => name.starts_with("claude-") && name.ends_with(".json"),
            ProviderKind::Antigravity => {
                name == "antigravity.json"
                    || (name.starts_with("antigravity-") && name.ends_with(".json"))
            }
        }
    }
}

/// Map a sub2api/Cockpit platform name to a provider. Unknown platforms stay
/// with the Codex importer (or are counted as skipped) instead of being
/// guessed.
pub fn kind_for_platform(value: &str) -> Option<ProviderKind> {
    match value.trim().to_ascii_lowercase().as_str() {
        "claude" | "anthropic" | "claude-code" | "claude_code" => Some(ProviderKind::Claude),
        "antigravity" | "google-antigravity" | "google_antigravity" => {
            Some(ProviderKind::Antigravity)
        }
        _ => None,
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProviderCredential {
    pub kind: ProviderKind,
    pub email: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub id_token: Option<String>,
    pub project_id: Option<String>,
    pub account_uuid: Option<String>,
    pub organization_uuid: Option<String>,
    pub organization_name: Option<String>,
    pub expired: Option<String>,
    pub expires_in: Option<i64>,
    pub timestamp: Option<i64>,
    pub last_refresh: Option<String>,
}

impl ProviderCredential {
    /// Stable de-duplication key for entries in one JSON file. Email is the
    /// human identity; a token fingerprint is the fallback when the export
    /// carries no email.
    pub fn dedupe_key(&self) -> String {
        let identity = self
            .email
            .as_deref()
            .map(|email| email.to_lowercase())
            .or_else(|| self.account_uuid.clone())
            .or_else(|| self.project_id.clone())
            .or_else(|| self.refresh_token.clone())
            .or_else(|| self.access_token.clone())
            .unwrap_or_default();
        format!(
            "{}:{}:{}",
            self.kind.type_name(),
            identity,
            self.organization_uuid.as_deref().unwrap_or("")
        )
    }

    fn identity_token(&self) -> &str {
        self.refresh_token
            .as_deref()
            .or(self.access_token.as_deref())
            .or(self.email.as_deref())
            .unwrap_or("provider")
    }

    fn expired_value(&self) -> Option<String> {
        if self.expired.is_some() {
            return self.expired.clone();
        }
        let seconds = self.expires_in?;
        let base = self.timestamp.unwrap_or_else(now_millis);
        epoch_rfc3339(base.saturating_add(seconds.saturating_mul(1000)))
    }
}

/// Parse one provider entry. `entry` may be flat (Cockpit/CPA) or wrap the
/// OAuth triple in `credentials` / `tokens` (sub2api).
pub fn parse(entry: &Map<String, Value>, kind: ProviderKind) -> Option<ProviderCredential> {
    let flat = entry
        .get("credentials")
        .and_then(Value::as_object)
        .or_else(|| entry.get("tokens").and_then(Value::as_object))
        .unwrap_or(entry);

    let access = text(flat, &["access_token"]).or_else(|| text(entry, &["access_token"]));
    let refresh = text(flat, &["refresh_token"]).or_else(|| text(entry, &["refresh_token"]));
    if access.is_none() && refresh.is_none() {
        return None;
    }

    let email = text(flat, &["email"])
        .or_else(|| text(entry, &["email"]))
        .or_else(|| email_name(entry))
        .or_else(|| email_name(flat));
    let project_id = text(flat, &["project_id", "projectId", "project"])
        .or_else(|| text(entry, &["project_id", "projectId", "project"]));
    let account_uuid = text(flat, &["account_uuid", "account_id", "chatgpt_account_id"])
        .or_else(|| text(entry, &["account_uuid", "account_id", "chatgpt_account_id"]));
    let organization_uuid = text(
        flat,
        &[
            "organization_uuid",
            "organization_id",
            "organizationId",
            "org_id",
        ],
    )
    .or_else(|| {
        text(
            entry,
            &[
                "organization_uuid",
                "organization_id",
                "organizationId",
                "org_id",
            ],
        )
    });
    let organization_name = text(flat, &["organization_name", "organizationName"])
        .or_else(|| text(entry, &["organization_name", "organizationName"]));

    let expires_in = integer(flat, &["expires_in"]).or_else(|| integer(entry, &["expires_in"]));
    let timestamp = integer(flat, &["timestamp"]).or_else(|| integer(entry, &["timestamp"]));

    Some(ProviderCredential {
        kind,
        email,
        access_token: access,
        refresh_token: refresh,
        id_token: text(flat, &["id_token"]).or_else(|| text(entry, &["id_token"])),
        project_id,
        account_uuid,
        organization_uuid,
        organization_name,
        expired: expiry(flat).or_else(|| expiry(entry)),
        expires_in,
        timestamp,
        last_refresh: text(flat, &["last_refresh", "lastRefresh"])
            .or_else(|| text(entry, &["last_refresh", "lastRefresh"])),
    })
}

/// Write every credential into `dir` and return `(claude, antigravity)`.
/// Existing engine-written files for the same email are updated in place, so
/// device ids and other engine metadata survive the import.
pub fn write_all(credentials: &[ProviderCredential], dir: &Path) -> Result<(usize, usize), String> {
    if credentials.is_empty() {
        return Ok((0, 0));
    }
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;

    let mut seen = HashSet::new();
    let mut claude = 0usize;
    let mut antigravity = 0usize;
    for credential in credentials {
        if !seen.insert(credential.dedupe_key()) {
            continue;
        }
        let path = target_path(dir, credential);
        write_one(&path, credential)?;
        match credential.kind {
            ProviderKind::Claude => claude += 1,
            ProviderKind::Antigravity => antigravity += 1,
        }
    }
    Ok((claude, antigravity))
}

fn target_path(dir: &Path, credential: &ProviderCredential) -> PathBuf {
    if let Some(email) = credential.email.as_deref() {
        if let Some(path) = existing_for_email(dir, credential, email) {
            return path;
        }
    }
    let identity = credential
        .email
        .as_deref()
        .map(sanitize)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| short_hash(credential.identity_token()));
    dir.join(format!("{}-{}.json", credential.kind.type_name(), identity))
}

fn existing_for_email(dir: &Path, credential: &ProviderCredential, email: &str) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    let wanted = email.trim().to_lowercase();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with("._") || !credential.kind.is_auth_file(&name) {
            continue;
        }
        let path = entry.path();
        let Ok(data) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(Value::Object(object)) = serde_json::from_str::<Value>(&data) else {
            continue;
        };
        let existing_email = object
            .get("email")
            .and_then(Value::as_str)
            .map(|value| value.trim().to_lowercase());
        if existing_email.as_deref() != Some(wanted.as_str()) {
            continue;
        }
        if let (Some(wanted_org), Some(existing_org)) = (
            credential.organization_uuid.as_deref(),
            object
                .get("organization_uuid")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty()),
        ) {
            if wanted_org != existing_org {
                continue;
            }
        }
        return Some(path);
    }
    None
}

fn write_one(path: &Path, credential: &ProviderCredential) -> Result<(), String> {
    let mut object = std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();

    object.insert("type".to_string(), json!(credential.kind.type_name()));
    // A fresh import is an explicit request to use the account again; a stale
    // cooldown flag from the engine must not keep it out of rotation.
    object.remove("disabled");
    set_text(&mut object, "email", credential.email.as_deref());
    set_text(
        &mut object,
        "access_token",
        credential.access_token.as_deref(),
    );
    set_text(
        &mut object,
        "refresh_token",
        credential.refresh_token.as_deref(),
    );
    set_text(&mut object, "id_token", credential.id_token.as_deref());
    set_text(&mut object, "project_id", credential.project_id.as_deref());
    set_text(
        &mut object,
        "account_uuid",
        credential.account_uuid.as_deref(),
    );
    set_text(
        &mut object,
        "organization_uuid",
        credential.organization_uuid.as_deref(),
    );
    set_text(
        &mut object,
        "organization_name",
        credential.organization_name.as_deref(),
    );
    if let Some(expired) = credential.expired_value() {
        object.insert("expired".to_string(), json!(expired));
    }
    if let Some(seconds) = credential.expires_in {
        object.insert("expires_in".to_string(), json!(seconds));
    }
    object.insert(
        "timestamp".to_string(),
        json!(credential.timestamp.unwrap_or_else(now_millis)),
    );
    object.insert(
        "last_refresh".to_string(),
        json!(credential.last_refresh.clone().unwrap_or_else(now_rfc3339)),
    );

    let text =
        serde_json::to_string_pretty(&Value::Object(object)).map_err(|e| e.to_string())? + "\n";
    write_atomic(path, &text)
}

fn write_atomic(path: &Path, data: &str) -> Result<(), String> {
    let tmp = paths::tmp_path(path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

fn text(map: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        map.get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(String::from)
    })
}

fn email_name(map: &Map<String, Value>) -> Option<String> {
    text(map, &["name"]).filter(|value| value.contains('@'))
}

fn integer(map: &Map<String, Value>, keys: &[&str]) -> Option<i64> {
    keys.iter().find_map(|key| {
        let value = map.get(*key)?;
        value
            .as_i64()
            .or_else(|| value.as_str()?.trim().parse::<i64>().ok())
    })
}

fn expiry(map: &Map<String, Value>) -> Option<String> {
    for key in ["expired", "expires_at", "expiresAt", "expire", "expiry"] {
        let Some(value) = map.get(key) else {
            continue;
        };
        if let Some(text) = value.as_str() {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(trimmed) {
                return Some(
                    parsed
                        .with_timezone(&chrono::Utc)
                        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                );
            }
            if let Ok(seconds) = trimmed.parse::<f64>() {
                if let Some(value) = epoch_rfc3339(seconds as i64) {
                    return Some(value);
                }
            }
            return Some(trimmed.to_string());
        }
        if let Some(number) = value.as_i64() {
            if let Some(value) = epoch_rfc3339(number) {
                return Some(value);
            }
        }
        if let Some(number) = value.as_f64() {
            if let Some(value) = epoch_rfc3339(number as i64) {
                return Some(value);
            }
        }
    }
    None
}

fn epoch_rfc3339(value: i64) -> Option<String> {
    let seconds = if value > 100_000_000_000 {
        value / 1000
    } else {
        value
    };
    chrono::DateTime::<chrono::Utc>::from_timestamp(seconds, 0)
        .map(|date| date.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn sanitize(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|character| match character {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .take(120)
        .collect()
}

fn short_hash(value: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(value.as_bytes());
    digest[..4]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn set_text(object: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value.filter(|value| !value.is_empty()) {
        object.insert(key.to_string(), json!(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "melon-provider-import-{}-{}",
            std::process::id(),
            tag
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn entry(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap()
    }

    #[test]
    fn platform_names_map_to_provider_kinds() {
        assert_eq!(kind_for_platform("anthropic"), Some(ProviderKind::Claude));
        assert_eq!(kind_for_platform("claude"), Some(ProviderKind::Claude));
        assert_eq!(
            kind_for_platform("google-antigravity"),
            Some(ProviderKind::Antigravity)
        );
        assert_eq!(
            kind_for_platform("Antigravity"),
            Some(ProviderKind::Antigravity)
        );
        assert_eq!(kind_for_platform("openai"), None);
        assert_eq!(kind_for_platform("gemini"), None);
    }

    #[test]
    fn claude_and_antigravity_are_written_with_engine_fields() {
        let dir = temp_dir("write");
        let claude = parse(
            &entry(json!({
                "platform": "anthropic",
                "credentials": {
                    "email": "claude@example.com",
                    "access_token": "access-1",
                    "refresh_token": "refresh-1",
                    "expires_at": "2026-11-01T12:00:00Z"
                }
            })),
            ProviderKind::Claude,
        )
        .unwrap();
        let antigravity = parse(
            &entry(json!({
                "platform": "antigravity",
                "credentials": {
                    "email": "google@example.com",
                    "access_token": "access-2",
                    "refresh_token": "refresh-2",
                    "project_id": "project-2",
                    "expires_in": 3600
                }
            })),
            ProviderKind::Antigravity,
        )
        .unwrap();

        let (claude_count, antigravity_count) = write_all(&[claude, antigravity], &dir).unwrap();
        assert_eq!((claude_count, antigravity_count), (1, 1));

        let claude_text = fs::read_to_string(dir.join("claude-claude@example.com.json")).unwrap();
        let claude_json: Value = serde_json::from_str(&claude_text).unwrap();
        assert_eq!(claude_json["type"], "claude");
        assert_eq!(claude_json["access_token"], "access-1");
        assert_eq!(claude_json["expired"], "2026-11-01T12:00:00Z");

        let antigravity_text =
            fs::read_to_string(dir.join("antigravity-google@example.com.json")).unwrap();
        let antigravity_json: Value = serde_json::from_str(&antigravity_text).unwrap();
        assert_eq!(antigravity_json["type"], "antigravity");
        assert_eq!(antigravity_json["project_id"], "project-2");
        assert_eq!(antigravity_json["expires_in"], 3600);
        assert!(antigravity_json["expired"].as_str().is_some());
    }

    #[test]
    fn existing_engine_metadata_survives_import() {
        let dir = temp_dir("merge");
        let path = dir.join("claude-00f765af-user@example.com.json");
        fs::write(
            &path,
            r#"{"type":"claude","email":"user@example.com","access_token":"old","disabled":true,"claude_device_ids":["device-1"],"organization_uuid":"org-1"}"#,
        )
        .unwrap();
        let credential = parse(
            &entry(json!({
                "platform": "claude",
                "credentials": {
                    "email": "user@example.com",
                    "access_token": "new",
                    "refresh_token": "refresh-1",
                    "organization_uuid": "org-1"
                }
            })),
            ProviderKind::Claude,
        )
        .unwrap();

        write_all(&[credential], &dir).unwrap();

        let json: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(json["access_token"], "new");
        assert_eq!(json["refresh_token"], "refresh-1");
        assert_eq!(json["claude_device_ids"], json!(["device-1"]));
        assert!(json.get("disabled").is_none());
    }

    #[test]
    fn duplicate_entries_are_written_once() {
        let dir = temp_dir("dupe");
        let first = parse(
            &entry(json!({
                "email": "same@example.com",
                "access_token": "a",
                "refresh_token": "r"
            })),
            ProviderKind::Claude,
        )
        .unwrap();
        let second = parse(
            &entry(json!({
                "email": "SAME@example.com",
                "access_token": "b",
                "refresh_token": "r2"
            })),
            ProviderKind::Claude,
        )
        .unwrap();
        let (count, _) = write_all(&[first, second], &dir).unwrap();
        assert_eq!(count, 1);
    }
}
