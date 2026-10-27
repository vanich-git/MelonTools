//! Local persistence schema guard.
//!
//! Every JSON store carries `schemaVersion` (files without it are version 1).
//! A file written by a newer build is opened read-only: writes return an
//! error and the UI gets a clear "update the app" message instead of losing
//! fields the older build does not know.

use std::sync::{Mutex, OnceLock};

pub const CURRENT: u32 = 2;

static SCHEMA_ERROR: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<String>> {
    SCHEMA_ERROR.get_or_init(|| Mutex::new(None))
}

/// Record one downgrade warning. The first message is kept; later reads of
/// the same newer file must not hide it.
pub fn note_newer(store: &str, found: u32) {
    if let Ok(mut error) = slot().lock() {
        if error.is_none() {
            *error = Some(format!(
                "{store} was written by a newer Melon Tools (schema {found}, this build supports {CURRENT}). Update the app before editing it."
            ));
        }
    }
}

pub fn error() -> Option<String> {
    slot().lock().ok().and_then(|error| error.clone())
}

/// Version of an existing JSON object file, `None` when missing/unreadable or
/// when the file predates schemaVersion (treated as 1).
pub fn file_version(path: &std::path::Path) -> Option<u32> {
    let text = std::fs::read_to_string(path).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    value
        .get("schemaVersion")
        .and_then(serde_json::Value::as_u64)
        .map(|value| value as u32)
}

/// Refuse to overwrite a file that a newer build owns.
pub fn ensure_writable(path: &std::path::Path, store: &str) -> Result<(), String> {
    if let Some(found) = file_version(path) {
        if found > CURRENT {
            note_newer(store, found);
            return Err(format!(
                "{store} was written by a newer Melon Tools (schema {found}). Update the app before saving."
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn newer_schema_is_read_but_refuses_writes() {
        let path = std::env::temp_dir().join(format!("melon-schema-{}.json", std::process::id()));
        let mut file = std::fs::File::create(&path).unwrap();
        file.write_all(br#"{"schemaVersion": 99}"#).unwrap();
        drop(file);
        assert_eq!(file_version(&path), Some(99));
        assert!(ensure_writable(&path, "vault").is_err());
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn missing_schema_means_version_one_and_is_writable() {
        let path =
            std::env::temp_dir().join(format!("melon-schema-old-{}.json", std::process::id()));
        std::fs::write(&path, br#"{"accounts": []}"#).unwrap();
        assert_eq!(file_version(&path), None);
        ensure_writable(&path, "vault").unwrap();
        std::fs::remove_file(&path).ok();
    }
}
