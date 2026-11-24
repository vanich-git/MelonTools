//! Opt-in state for the native plugin host on Windows.
//!
//! Kept out of `Settings` on purpose: plugin hosting is an execution policy,
//! not a provider setting, and a separate tiny JSON file can be read while the
//! gateway config is rendered without touching the settings merge logic.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::{gateway, paths};

pub const DEFAULT_REGISTRY_URL: &str =
    "https://raw.githubusercontent.com/vanich-git/MelonTools/main/registry/registry.json";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct PluginPrefs {
    /// Native code execution is opt-in. A fresh profile writes `false`, so a
    /// config render alone never loads a third-party library.
    pub host_enabled: bool,
    /// Empty means the built-in Melon registry. The official CLIProxyAPI
    /// registry is always added by the engine.
    pub registry_url: String,
}

impl Default for PluginPrefs {
    fn default() -> Self {
        Self {
            host_enabled: false,
            registry_url: DEFAULT_REGISTRY_URL.to_string(),
        }
    }
}

pub fn prefs_path() -> PathBuf {
    paths::appdata_dir().join("plugin-prefs.json")
}

pub fn load() -> PluginPrefs {
    let Ok(raw) = std::fs::read_to_string(prefs_path()) else {
        return PluginPrefs::default();
    };
    let mut prefs: PluginPrefs = serde_json::from_str(&raw).unwrap_or_default();
    if prefs.registry_url.trim().is_empty() {
        prefs.registry_url = DEFAULT_REGISTRY_URL.to_string();
    }
    prefs
}

pub fn save(prefs: &PluginPrefs) -> Result<(), String> {
    let path = prefs_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let data = serde_json::to_string_pretty(prefs).map_err(|e| e.to_string())?;
    let tmp = paths::tmp_path(&path);
    std::fs::write(&tmp, data).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

pub fn plugins_dir() -> PathBuf {
    paths::gateway_dir().join("plugins")
}

/// Absolute path handed to the engine. `plugins.dir` must be absolute: the
/// sidecar is started without a working directory, so a relative path would
/// resolve against the install folder and discovery would come up empty.
pub fn ensure_plugins_dir() -> Result<PathBuf, String> {
    let dir = plugins_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

/// Appended to every generated gateway config. Emitted even while disabled so
/// the store can be inspected without enabling native execution.
pub fn gateway_yaml() -> String {
    // The engine refuses to start when plugins.dir is missing, and the first
    // config render can happen before any plugin UI exists. Create it here so
    // a fresh install boots with the host disabled but a valid directory.
    let _ = ensure_plugins_dir();
    let prefs = load();
    let dir = gateway::yaml_escape(&paths::yaml_path(&plugins_dir()));
    let source = gateway::yaml_escape(prefs.registry_url.trim());
    format!(
        r#"
# Native plugins. The host loads dynamic libraries in process, so installs
# require explicit consent in the app.
plugins:
  enabled: {}
  dir: "{}"
  store-sources:
    - "{}"
"#,
        if prefs.host_enabled { "true" } else { "false" },
        dir,
        source
    )
}
