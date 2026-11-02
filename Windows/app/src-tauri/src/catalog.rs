//! Completes the engine's general model catalog for Antigravity.
//!
//! The engine ships one Antigravity entry per model family —
//! `gemini-3.8-flash-high` stands for all 3.8 Flash thinking levels. Google
//! exposes a separate id for each level and for Gemini 2.5 Pro, so those ids
//! never pass the engine's catalog ∩ account intersection and never reach
//! `/v1/models`.
//!
//! The app fetches the same official catalog the engine would fetch, adds the
//! missing Antigravity definitions, validates the result and writes it next to
//! the gateway config. `config.yaml` then points `models.catalog` at the file,
//! so the fix survives restarts and settings saves.
//!
//! Merge and validation are pure: tests exercise them without touching the
//! network or the live gateway.

use serde_json::{Map, Value};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

use crate::paths;

/// Same sources, in the same order, as the engine's own catalog updater.
pub const OFFICIAL_URLS: [&str; 2] = [
    "https://raw.githubusercontent.com/router-for-me/models/refs/heads/main/models.json",
    "https://models.router-for.me/models.json",
];

/// Sections the engine validates. A candidate missing one would replace the
/// whole catalog and empty the affected providers.
const REQUIRED_SECTIONS: [&str; 12] = [
    "claude",
    "gemini",
    "vertex",
    "aistudio",
    "codex-free",
    "codex-team",
    "codex-plus",
    "codex-pro",
    "kimi",
    "antigravity",
    "xai",
    "meta",
];

/// The engine re-reads its catalog source on this cadence; the overlay follows
/// it so the file never lags behind the official one.
const REFRESH_INTERVAL: Duration = Duration::from_secs(3 * 60 * 60);
/// A failed fetch is retried on this cadence, not on every watchdog tick.
const RETRY_INTERVAL: Duration = Duration::from_secs(15 * 60);
const STARTUP_TIMEOUT: Duration = Duration::from_secs(10);
const BACKGROUND_TIMEOUT: Duration = Duration::from_secs(45);

/// Antigravity ids that are missing from the official catalog but are real,
/// entitled models in the account catalog.
struct ExtraModel {
    id: &'static str,
    display: &'static str,
    /// Existing catalog entry to clone.
    template_id: &'static str,
    template_section: &'static str,
}

const EXTRA_MODELS: [ExtraModel; 3] = [
    ExtraModel {
        id: "gemini-3.8-flash-low",
        display: "Gemini 3.8 Flash (Low)",
        template_id: "gemini-3.8-flash-high",
        template_section: "antigravity",
    },
    ExtraModel {
        id: "gemini-3.8-flash-medium",
        display: "Gemini 3.8 Flash (Medium)",
        template_id: "gemini-3.8-flash-high",
        template_section: "antigravity",
    },
    ExtraModel {
        id: "gemini-2.5-pro",
        display: "Gemini 2.5 Pro",
        template_id: "gemini-2.5-pro",
        template_section: "gemini",
    },
];

/// `gateway/models.json` next to the engine config.
pub fn catalog_path() -> PathBuf {
    paths::gateway_dir().join("models.json")
}

/// Top-level YAML block for `config.yaml`; empty when the overlay is not on
/// disk, so the engine keeps its own catalog.
pub fn config_block() -> String {
    config_block_at(&catalog_path())
}

fn config_block_at(path: &Path) -> String {
    if !path.is_file() {
        return String::new();
    }
    let value = path.to_string_lossy();
    format!(
        "models:\n  catalog: \"{}\"\n",
        crate::gateway::yaml_escape(&value)
    )
}

// MARK: - Pure catalog work

/// Dedupes every model array, then appends the extra Antigravity entries.
///
/// Deduplication comes first: one duplicate id makes the engine reject the
/// whole catalog, and the official catalog is the only source that can
/// introduce one.
pub fn merge(catalog: &Value) -> Value {
    let Some(root) = catalog.as_object() else {
        return catalog.clone();
    };
    let mut merged: Map<String, Value> = root.clone();
    let keys: Vec<String> = merged.keys().cloned().collect();
    for key in keys {
        let Some(Value::Array(models)) = merged.get(&key) else {
            continue;
        };
        let models = deduplicated(models);
        merged.insert(key, Value::Array(models));
    }

    let extras = extra_entries(&merged);
    if !extras.is_empty() {
        let entry = merged
            .entry("antigravity".to_string())
            .or_insert_with(|| Value::Array(Vec::new()));
        if let Some(models) = entry.as_array_mut() {
            let mut known: HashSet<String> = models
                .iter()
                .filter_map(|model| model.get("id").and_then(Value::as_str))
                .map(str::to_string)
                .collect();
            for extra in extras {
                let id = extra
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                if !id.is_empty() && known.insert(id) {
                    models.push(extra);
                }
            }
        }
    }
    Value::Object(merged)
}

/// Mirrors the engine's `validateModelSection`: required sections must be
/// arrays of objects with non-empty, unique ids.
pub fn validate(catalog: &Value) -> Result<(), String> {
    let Some(root) = catalog.as_object() else {
        return Err("catalog is not an object".to_string());
    };
    for section in REQUIRED_SECTIONS {
        let Some(raw) = root.get(section) else {
            return Err(format!("missing section {section}"));
        };
        let Some(models) = raw.as_array() else {
            return Err(format!("section {section} is not a model array"));
        };
        let mut seen = HashSet::with_capacity(models.len());
        for (index, model) in models.iter().enumerate() {
            let id = model
                .get("id")
                .and_then(Value::as_str)
                .map(str::trim)
                .unwrap_or_default();
            if id.is_empty() {
                return Err(format!("{section}[{index}] has an empty id"));
            }
            if !seen.insert(id.to_string()) {
                return Err(format!("{section} contains duplicate id {id}"));
            }
        }
    }
    Ok(())
}

fn extra_entries(catalog: &Map<String, Value>) -> Vec<Value> {
    EXTRA_MODELS
        .iter()
        .filter_map(|extra| {
            let section = catalog
                .get(extra.template_section)
                .and_then(Value::as_array)?;
            let template = section
                .iter()
                .find(|model| model.get("id").and_then(Value::as_str) == Some(extra.template_id))?;
            let mut entry = template.as_object()?.clone();
            entry.insert("id".to_string(), Value::from(extra.id));
            entry.insert("name".to_string(), Value::from(extra.id));
            entry.insert("display_name".to_string(), Value::from(extra.display));
            entry.insert("description".to_string(), Value::from(extra.display));
            if extra.template_section != "antigravity" {
                entry.insert("owned_by".to_string(), Value::from("antigravity"));
                entry.insert("type".to_string(), Value::from("antigravity"));
                // Gemini-section entries carry the window as inputTokenLimit;
                // mirror it in the flat keys `/v1/models` consumers read.
                if let Some(input) = entry.get("inputTokenLimit").and_then(Value::as_u64) {
                    entry.insert("context_length".to_string(), Value::from(input));
                }
                if let Some(output) = entry.get("outputTokenLimit").and_then(Value::as_u64) {
                    entry.insert("max_completion_tokens".to_string(), Value::from(output));
                }
            }
            Some(Value::Object(entry))
        })
        .collect()
}

fn deduplicated(models: &[Value]) -> Vec<Value> {
    let mut seen = HashSet::with_capacity(models.len());
    models
        .iter()
        .filter(|model| {
            let id = model
                .get("id")
                .and_then(Value::as_str)
                .map(str::trim)
                .unwrap_or_default();
            !id.is_empty() && seen.insert(id.to_string())
        })
        .cloned()
        .collect()
}

// MARK: - Refresh

/// Whether the overlay is missing or older than the refresh cadence.
pub fn needs_refresh() -> bool {
    needs_refresh_at(&catalog_path(), SystemTime::now())
}

fn needs_refresh_at(path: &Path, now: SystemTime) -> bool {
    let Ok(modified) = fs::metadata(path).and_then(|meta| meta.modified()) else {
        return true;
    };
    now.duration_since(modified).unwrap_or_default() >= REFRESH_INTERVAL
}

static REFRESHING: AtomicBool = AtomicBool::new(false);
static LAST_ATTEMPT: Mutex<Option<Instant>> = Mutex::new(None);

pub fn is_refreshing() -> bool {
    REFRESHING.load(Ordering::SeqCst)
}

/// Refreshes the overlay when it is missing or stale.
///
/// Returns `true` when a new file was written. `timeout` bounds the whole
/// operation so gateway startup never waits on an unreachable host.
pub async fn refresh_if_needed(timeout: Duration) -> bool {
    if !needs_refresh() {
        return false;
    }
    if REFRESHING.swap(true, Ordering::SeqCst) {
        return false;
    }
    if let Ok(guard) = LAST_ATTEMPT.lock() {
        if let Some(last) = *guard {
            if last.elapsed() < RETRY_INTERVAL {
                REFRESHING.store(false, Ordering::SeqCst);
                return false;
            }
        }
    }

    let updated = tokio::time::timeout(timeout, perform_refresh())
        .await
        .unwrap_or(false);

    if let Ok(mut guard) = LAST_ATTEMPT.lock() {
        *guard = if updated { None } else { Some(Instant::now()) };
    }
    REFRESHING.store(false, Ordering::SeqCst);
    updated
}

/// Startup uses a tighter budget than the background refresh.
pub async fn refresh_for_start() -> bool {
    refresh_if_needed(STARTUP_TIMEOUT).await
}

pub async fn refresh_in_background() -> bool {
    refresh_if_needed(BACKGROUND_TIMEOUT).await
}

async fn perform_refresh() -> bool {
    let Some(bytes) = fetch_catalog().await else {
        return false;
    };
    let Ok(root) = serde_json::from_slice::<Value>(&bytes) else {
        return false;
    };
    let merged = merge(&root);
    if validate(&merged).is_err() {
        return false;
    }
    let Ok(text) = serde_json::to_vec(&merged) else {
        return false;
    };
    let path = catalog_path();
    let Some(parent) = path.parent() else {
        return false;
    };
    if fs::create_dir_all(parent).is_err() {
        return false;
    }
    // Temp + rename: the engine must never read a half-written catalog.
    let tmp = paths::tmp_path(&path);
    if fs::write(&tmp, text).is_err() {
        return false;
    }
    fs::rename(&tmp, &path).is_ok()
}

async fn fetch_catalog() -> Option<Vec<u8>> {
    let client = crate::proxy::apply(reqwest::Client::builder())
        .timeout(Duration::from_secs(20))
        .build()
        .ok()?;
    for url in OFFICIAL_URLS {
        let Ok(response) = client
            .get(url)
            .header("User-Agent", crate::gateway::USER_AGENT)
            .send()
            .await
        else {
            continue;
        };
        if !response.status().is_success() {
            continue;
        }
        let Ok(bytes) = response.bytes().await else {
            continue;
        };
        if !bytes.is_empty() {
            return Some(bytes.to_vec());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn template_catalog() -> Value {
        let mut catalog = serde_json::Map::new();
        for section in REQUIRED_SECTIONS {
            catalog.insert(section.to_string(), json!([]));
        }
        catalog.insert(
            "antigravity".to_string(),
            json!([
                {
                    "id": "gemini-3.8-flash-high",
                    "object": "model",
                    "owned_by": "antigravity",
                    "type": "antigravity",
                    "name": "gemini-3.8-flash-high",
                    "display_name": "Gemini 3.8 Flash",
                    "context_length": 1048576,
                    "max_completion_tokens": 65536
                },
                {
                    "id": "gemini-3-flash",
                    "object": "model",
                    "owned_by": "antigravity",
                    "type": "antigravity"
                }
            ]),
        );
        catalog.insert(
            "gemini".to_string(),
            json!([
                {
                    "id": "gemini-2.5-pro",
                    "object": "model",
                    "owned_by": "google",
                    "type": "gemini",
                    "name": "models/gemini-2.5-pro",
                    "display_name": "Gemini 2.5 Pro",
                    "inputTokenLimit": 1048576,
                    "outputTokenLimit": 65536
                }
            ]),
        );
        Value::Object(catalog)
    }

    fn antigravity_ids(catalog: &Value) -> Vec<String> {
        catalog["antigravity"]
            .as_array()
            .map(|models| {
                models
                    .iter()
                    .filter_map(|model| model["id"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn merge_adds_the_three_missing_antigravity_models() {
        let merged = merge(&template_catalog());
        let ids = antigravity_ids(&merged);
        assert_eq!(
            ids.iter()
                .filter(|id| *id == "gemini-3.8-flash-low")
                .count(),
            1
        );
        assert_eq!(
            ids.iter()
                .filter(|id| *id == "gemini-3.8-flash-medium")
                .count(),
            1
        );
        assert_eq!(ids.iter().filter(|id| *id == "gemini-2.5-pro").count(), 1);

        let models = merged["antigravity"].as_array().unwrap();
        let pro = models
            .iter()
            .find(|model| model["id"] == "gemini-2.5-pro")
            .unwrap();
        assert_eq!(pro["owned_by"], "antigravity");
        assert_eq!(pro["type"], "antigravity");
        assert_eq!(pro["context_length"], 1048576);
        assert_eq!(pro["max_completion_tokens"], 65536);

        let medium = models
            .iter()
            .find(|model| model["id"] == "gemini-3.8-flash-medium")
            .unwrap();
        assert_eq!(medium["display_name"], "Gemini 3.8 Flash (Medium)");
        assert_eq!(medium["context_length"], 1048576);
    }

    #[test]
    fn merge_deduplicates_ids_so_the_engine_accepts_the_catalog() {
        let mut catalog = template_catalog();
        let mut models = catalog["antigravity"].as_array().unwrap().clone();
        models.push(models[0].clone());
        catalog["antigravity"] = Value::Array(models);

        let merged = merge(&catalog);
        let ids = antigravity_ids(&merged);
        assert_eq!(
            ids.iter()
                .filter(|id| *id == "gemini-3.8-flash-high")
                .count(),
            1
        );
        assert!(validate(&merged).is_ok());
    }

    #[test]
    fn merge_does_not_duplicate_an_entry_that_already_exists() {
        let mut catalog = template_catalog();
        let mut models = catalog["antigravity"].as_array().unwrap().clone();
        models.push(json!({
            "id": "gemini-3.8-flash-low",
            "object": "model",
            "owned_by": "antigravity",
            "type": "antigravity"
        }));
        catalog["antigravity"] = Value::Array(models);

        let merged = merge(&catalog);
        assert_eq!(
            antigravity_ids(&merged)
                .iter()
                .filter(|id| *id == "gemini-3.8-flash-low")
                .count(),
            1
        );
    }

    #[test]
    fn validate_rejects_missing_sections_and_duplicate_ids() {
        let mut catalog = template_catalog();
        catalog.as_object_mut().unwrap().remove("xai");
        assert_eq!(validate(&catalog).unwrap_err(), "missing section xai");

        let mut catalog = template_catalog();
        catalog["antigravity"] = json!([{ "id": "gemini-3-flash" }, { "id": "gemini-3-flash" }]);
        assert!(validate(&catalog).is_err());

        catalog["antigravity"] = json!([{ "id": "  " }]);
        assert!(validate(&catalog).is_err());
    }

    #[test]
    fn config_block_requires_an_existing_file() {
        let dir = std::env::temp_dir().join(format!(
            "melon-catalog-config-{}-{:?}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("models.json");
        assert_eq!(config_block_at(&path), "");
        fs::write(&path, "{}").unwrap();
        let block = config_block_at(&path);
        assert!(block.starts_with("models:\n  catalog: \""));
        assert!(block.contains("models.json"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn needs_refresh_follows_the_file_age() {
        let dir = std::env::temp_dir().join(format!(
            "melon-catalog-age-{}-{:?}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("models.json");
        assert!(needs_refresh_at(&path, SystemTime::now()));
        fs::write(&path, "{}").unwrap();
        assert!(!needs_refresh_at(&path, SystemTime::now()));
        assert!(needs_refresh_at(
            &path,
            SystemTime::now() + REFRESH_INTERVAL + Duration::from_secs(60)
        ));
        let _ = fs::remove_dir_all(&dir);
    }
}
