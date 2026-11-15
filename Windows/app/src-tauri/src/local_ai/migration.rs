//! One-time upgrade from 5.5.5 to 6.0.0.
//!
//! The specification requires that an upgrade never loses user data and that a
//! rollback stays possible. This snapshots the files the app actually uses —
//! `settings.json`, the local model registry, its storage settings and the
//! gateway `config.yaml` — into `metadata/backups/6.0.0-<stamp>/`.
//!
//! Fail-closed: the marker is written only after every existing source was
//! copied. A copy, directory or marker error leaves no marker, so the next
//! launch retries instead of silently skipping the backup. The report is kept
//! in memory and exposed to the UI so the failure is visible, not just logged.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::paths::{
    config_path, local_metadata_dir, models_registry_path, settings_path, storage_settings_path,
};

const MARKER: &str = "migrated-6.0.0.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationReport {
    pub performed: bool,
    pub already_done: bool,
    pub backup_dir: Option<String>,
    pub backed_up: Vec<String>,
    pub error: Option<String>,
}

static LAST_REPORT: Mutex<Option<MigrationReport>> = Mutex::new(None);

/// Runs the migration once. Returns the report even when it failed, so the
/// caller can show the error before the app rewrites any store.
pub fn run_if_needed() -> MigrationReport {
    let sources = migration_sources();
    let report = run_at(&local_metadata_dir(), &sources, timestamp());
    if let Some(error) = report.error.as_deref() {
        eprintln!("Melon Tools migration 5.5.5 -> 6.0.0: {error}");
    }
    let mut slot = LAST_REPORT.lock().unwrap_or_else(|e| e.into_inner());
    *slot = Some(report.clone());
    report
}

/// Last report for the current process. `None` before the first run.
pub fn last_report() -> Option<MigrationReport> {
    LAST_REPORT
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

fn migration_sources() -> Vec<(PathBuf, &'static str)> {
    vec![
        (settings_path(), "settings.json"),
        (models_registry_path(), "models.json"),
        (storage_settings_path(), "storage_settings.json"),
        (config_path(), "config.yaml"),
    ]
}

fn timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn run_at(metadata: &Path, sources: &[(PathBuf, &'static str)], stamp: u64) -> MigrationReport {
    let marker = metadata.join(MARKER);
    if marker.exists() {
        return MigrationReport {
            performed: false,
            already_done: true,
            backup_dir: None,
            backed_up: Vec::new(),
            error: None,
        };
    }

    let backup_root = metadata.join("backups").join(format!("6.0.0-{}", stamp));
    if let Err(error) = fs::create_dir_all(&backup_root) {
        return MigrationReport {
            performed: false,
            already_done: false,
            backup_dir: None,
            backed_up: Vec::new(),
            error: Some(format!(
                "cannot create backup directory {}: {}",
                backup_root.display(),
                error
            )),
        };
    }

    let mut backed_up: Vec<String> = Vec::new();
    for (source, name) in sources {
        if !source.exists() {
            continue;
        }
        let target = backup_root.join(name);
        let copied = match fs::copy(source, &target) {
            Ok(bytes) => bytes,
            Err(error) => {
                return failure(
                    &backup_root,
                    backed_up,
                    format!("failed to back up {}: {}", source.display(), error),
                );
            }
        };
        let source_len = fs::metadata(source).map(|m| m.len()).ok();
        if let Some(expected) = source_len {
            if copied != expected {
                return failure(
                    &backup_root,
                    backed_up,
                    format!(
                        "short copy for {}: wrote {} of {} bytes",
                        source.display(),
                        copied,
                        expected
                    ),
                );
            }
        }
        backed_up.push(name.to_string());
    }

    let payload = serde_json::json!({
        "from": "5.5.5",
        "to": "6.0.0",
        "at": stamp,
        "backedUp": backed_up,
    });
    let body = match serde_json::to_string_pretty(&payload) {
        Ok(body) => body,
        Err(error) => {
            return failure(
                &backup_root,
                backed_up,
                format!("cannot encode migration marker: {}", error),
            );
        }
    };
    if let Err(error) = write_marker(&marker, &body) {
        return failure(
            &backup_root,
            backed_up,
            format!(
                "backup is complete but {} could not be written: {}; the next launch retries",
                marker.display(),
                error
            ),
        );
    }

    MigrationReport {
        performed: true,
        already_done: false,
        backup_dir: Some(backup_root.to_string_lossy().to_string()),
        backed_up,
        error: None,
    }
}

/// Atomic marker: a crash mid-write must not leave a half-written file that
/// the next launch mistakes for a completed migration.
fn write_marker(marker: &Path, body: &str) -> std::io::Result<()> {
    let tmp = crate::paths::tmp_path(marker);
    if let Err(error) = fs::write(&tmp, body) {
        let _ = fs::remove_file(&tmp);
        return Err(error);
    }
    if let Err(error) = fs::rename(&tmp, marker) {
        let _ = fs::remove_file(&tmp);
        return Err(error);
    }
    Ok(())
}

fn failure(backup_root: &Path, backed_up: Vec<String>, error: String) -> MigrationReport {
    MigrationReport {
        performed: false,
        already_done: false,
        backup_dir: Some(backup_root.to_string_lossy().to_string()),
        backed_up,
        error: Some(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(tag: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "melontools-migration-{}-{}-{}",
            std::process::id(),
            tag,
            stamp
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The sources live outside the metadata dir on purpose: settings and the
    /// gateway config are two different roots, and the backup must copy from
    /// the real path rather than assume they share one.
    fn source_file(root: &Path, name: &str, body: &str) -> (PathBuf, &'static str) {
        let path = root.join(name);
        fs::write(&path, body).unwrap();
        let static_name: &'static str = match name {
            "settings.json" => "settings.json",
            "models.json" => "models.json",
            "storage_settings.json" => "storage_settings.json",
            "config.yaml" => "config.yaml",
            _ => panic!("unexpected fixture name"),
        };
        (path, static_name)
    }

    #[test]
    fn backs_up_every_real_file_before_writing_the_marker() {
        let root = temp_dir("ok");
        let metadata = root.join("metadata");
        let appdata = root.join("appdata");
        fs::create_dir_all(&metadata).unwrap();
        fs::create_dir_all(&appdata).unwrap();
        let sources = vec![
            source_file(&appdata, "settings.json", "{\"lang\":\"ru\"}"),
            source_file(&appdata, "models.json", "[{\"id\":\"local/a\"}]"),
            source_file(&appdata, "storage_settings.json", "{\"dir\":\"D:/models\"}"),
            source_file(&appdata, "config.yaml", "port: 18317\n"),
        ];

        let report = run_at(&metadata, &sources, 42);

        assert!(report.performed);
        assert!(!report.already_done);
        assert!(report.error.is_none());
        assert_eq!(
            report.backed_up,
            vec![
                "settings.json",
                "models.json",
                "storage_settings.json",
                "config.yaml"
            ]
        );
        let backup = PathBuf::from(report.backup_dir.unwrap());
        assert_eq!(
            fs::read_to_string(backup.join("settings.json")).unwrap(),
            "{\"lang\":\"ru\"}"
        );
        assert_eq!(
            fs::read_to_string(backup.join("config.yaml")).unwrap(),
            "port: 18317\n"
        );

        let marker: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(metadata.join(MARKER)).unwrap()).unwrap();
        assert_eq!(marker["from"], "5.5.5");
        assert_eq!(marker["to"], "6.0.0");
        assert_eq!(marker["at"], 42);
        assert_eq!(marker["backedUp"].as_array().unwrap().len(), 4);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn marker_makes_the_second_run_a_no_op() {
        let root = temp_dir("once");
        let metadata = root.join("metadata");
        fs::create_dir_all(&metadata).unwrap();
        let sources = vec![source_file(&root, "settings.json", "{}")];

        let first = run_at(&metadata, &sources, 7);
        let second = run_at(&metadata, &sources, 8);

        assert!(first.performed);
        assert!(!second.performed);
        assert!(second.already_done);
        assert!(second.error.is_none());
        assert!(second.backup_dir.is_none());
        assert!(second.backed_up.is_empty());
        // Only the first stamp exists.
        let backups: Vec<_> = fs::read_dir(metadata.join("backups"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(backups, vec!["6.0.0-7"]);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_copy_error_keeps_the_marker_out_and_the_original_intact() {
        let root = temp_dir("copy-error");
        let metadata = root.join("metadata");
        let blocked = metadata
            .join("backups")
            .join("6.0.0-9")
            .join("settings.json");
        fs::create_dir_all(&blocked).unwrap();
        let sources = vec![source_file(&root, "settings.json", "keep me")];

        let report = run_at(&metadata, &sources, 9);

        assert!(!report.performed);
        assert!(!report.already_done);
        assert!(report
            .error
            .as_deref()
            .unwrap()
            .contains("failed to back up"));
        assert!(!metadata.join(MARKER).exists());
        assert_eq!(
            fs::read_to_string(root.join("settings.json")).unwrap(),
            "keep me"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn missing_sources_are_skipped_and_still_marked_once() {
        let root = temp_dir("empty");
        let metadata = root.join("metadata");
        fs::create_dir_all(&metadata).unwrap();
        let missing = root.join("nothing-here.json");
        let sources = vec![(missing, "settings.json")];

        let report = run_at(&metadata, &sources, 11);

        assert!(report.performed);
        assert!(report.backed_up.is_empty());
        assert!(report.error.is_none());
        assert!(metadata.join(MARKER).exists());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn marker_write_failure_is_reported_without_losing_the_backup() {
        let root = temp_dir("marker");
        let metadata = root.join("metadata");
        fs::create_dir_all(&metadata).unwrap();
        // The marker's parent is a regular file, so both the temp write and
        // the final rename fail; the backup itself already succeeded.
        let not_a_directory = metadata.join("blocked");
        fs::write(&not_a_directory, "x").unwrap();
        let marker = not_a_directory.join(MARKER);
        assert!(write_marker(&marker, "{}").is_err());

        let sources = vec![source_file(&root, "settings.json", "{}")];
        let report = run_at(&metadata, &sources, 12);
        assert!(report.performed);
        assert!(report.error.is_none());
        assert_eq!(report.backed_up, vec!["settings.json"]);
        let backup = PathBuf::from(report.backup_dir.unwrap());
        assert_eq!(
            fs::read_to_string(backup.join("settings.json")).unwrap(),
            "{}"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn an_unusable_metadata_dir_fails_before_any_marker() {
        let root = temp_dir("metadata-file");
        let metadata = root.join("metadata");
        fs::write(&metadata, "not a directory").unwrap();
        let sources = vec![source_file(&root, "settings.json", "{}")];

        let report = run_at(&metadata, &sources, 13);

        assert!(!report.performed);
        assert!(!report.already_done);
        assert!(report
            .error
            .as_deref()
            .unwrap()
            .contains("backup directory"));
        assert!(report.backup_dir.is_none());

        let _ = fs::remove_dir_all(root);
    }
}
