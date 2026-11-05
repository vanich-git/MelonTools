//! Filesystem layout for Melon Tools on Windows.
//!
//! The account vault and gateway directory follow the macOS app's layout under
//! `%APPDATA%\MelonTools` so a vault copied from macOS keeps working.

use std::env;
use std::path::PathBuf;

pub fn appdata_dir() -> PathBuf {
    if let Ok(appdata) = env::var("APPDATA") {
        return PathBuf::from(appdata).join("MelonTools");
    }
    // Development fallback (running the check/build on macOS or Linux).
    PathBuf::from(env::var("HOME").unwrap_or_default())
        .join("Library/Application Support/MelonTools")
}

pub fn gateway_dir() -> PathBuf {
    appdata_dir().join("gateway")
}

pub fn auths_dir() -> PathBuf {
    gateway_dir().join("auths")
}

pub fn config_path() -> PathBuf {
    gateway_dir().join("config.yaml")
}

pub fn log_path() -> PathBuf {
    gateway_dir().join("gateway.log")
}

pub fn pid_path() -> PathBuf {
    gateway_dir().join("gateway.pid")
}

pub fn vault_path() -> PathBuf {
    appdata_dir().join("codex").join("accounts.json")
}

pub fn settings_path() -> PathBuf {
    appdata_dir().join("settings.json")
}

/// Portable model-source definitions (shared with the macOS layout).
#[allow(dead_code)]
pub fn model_sources_path() -> PathBuf {
    appdata_dir().join("model-sources.json")
}

/// Timestamp of the last successful backup export.
#[allow(dead_code)]
pub fn backup_state_path() -> PathBuf {
    appdata_dir().join("backup-state.json")
}

/// Default export directory: `%USERPROFILE%\Downloads`, with the appdata
/// directory as the last-resort fallback when the profile is unknown.
pub fn downloads_dir() -> PathBuf {
    if let Ok(profile) = env::var("USERPROFILE") {
        if !profile.trim().is_empty() {
            return PathBuf::from(profile).join("Downloads");
        }
    }
    if let Ok(home) = env::var("HOME") {
        if !home.trim().is_empty() {
            return PathBuf::from(home).join("Downloads");
        }
    }
    appdata_dir()
}

pub fn codex_home() -> PathBuf {
    if let Ok(profile) = env::var("USERPROFILE") {
        return PathBuf::from(profile).join(".codex");
    }
    PathBuf::from(env::var("HOME").unwrap_or_default()).join(".codex")
}

pub fn codex_auth_path() -> PathBuf {
    codex_home().join("auth.json")
}

// MARK: - Local AI Storage Paths (%LOCALAPPDATA%\MelonTools or fallback)

/// Root directory for Local AI models and runtime: `%LOCALAPPDATA%\MelonTools` on Windows,
/// or `~/Library/Application Support/MelonTools` on macOS/fallback.
pub fn local_ai_root_dir() -> PathBuf {
    if let Ok(local_appdata) = env::var("LOCALAPPDATA") {
        if !local_appdata.trim().is_empty() {
            return PathBuf::from(local_appdata).join("MelonTools");
        }
    }
    appdata_dir()
}

pub fn local_models_dir() -> PathBuf {
    local_ai_root_dir().join("models")
}

pub fn local_downloads_dir() -> PathBuf {
    local_ai_root_dir().join("downloads")
}

pub fn local_runtime_dir() -> PathBuf {
    local_ai_root_dir().join("runtime")
}

pub fn local_metadata_dir() -> PathBuf {
    local_ai_root_dir().join("metadata")
}

pub fn local_logs_dir() -> PathBuf {
    local_ai_root_dir().join("logs")
}

pub fn models_registry_path() -> PathBuf {
    local_metadata_dir().join("models.json")
}

pub fn storage_settings_path() -> PathBuf {
    local_metadata_dir().join("storage_settings.json")
}

pub fn llama_server_exe_path() -> PathBuf {
    if cfg!(windows) {
        local_runtime_dir().join("llama-server.exe")
    } else {
        local_runtime_dir().join("llama-server")
    }
}

/// YAML wants forward slashes: backslashes are escape characters.
pub fn yaml_path(p: &std::path::Path) -> String {
    p.to_string_lossy().replace('\\', "/")
}

/// A unique temporary sibling for atomic writes: two concurrent writers of
/// the same file must not share one tmp path — the rename would publish the
/// wrong content and the other writer would fail on a missing file.
/// Move an unreadable store aside instead of letting the next save overwrite
/// it. Returns the quarantined path when a file was moved.
pub fn quarantine(path: &std::path::Path) -> Option<PathBuf> {
    if !path.exists() {
        return None;
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let name = path
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "store".to_string());
    let target = path.with_file_name(format!("{name}.corrupt-{stamp}"));
    std::fs::rename(path, &target).ok()?;
    Some(target)
}

pub fn tmp_path(path: &std::path::Path) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let tick = COUNTER.fetch_add(1, Ordering::Relaxed);
    let name = path
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "tmp".to_string());
    path.with_file_name(format!(".{}.{}.{}.tmp", name, std::process::id(), tick))
}
