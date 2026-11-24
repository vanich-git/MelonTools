//! Usage telemetry, ported from the macOS Usage screen.
//!
//! The gateway writes one `[usage]` JSON line per finished request into
//! `%APPDATA%\MelonTools\usage\usage-YYYY-MM-DD.jsonl`. The app keeps those
//! files forever, so the Usage screen aggregates them on demand instead of
//! trusting an in-memory counter.

use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

use crate::paths;

/// Upper bound for one payload. A month of heavy routing stays below this, and
/// the screen only renders the newest slice anyway.
const DEFAULT_LIMIT: usize = 20_000;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct UsageEvent {
    pub id: String,
    pub at: String,
    pub model: String,
    pub provider: String,
    pub auth: String,
    pub input: u64,
    pub output: u64,
    pub mode: String,
    pub status: u16,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSnapshot {
    pub events: Vec<UsageEvent>,
    pub total: usize,
    pub files: usize,
    pub truncated: bool,
}

pub fn dir() -> PathBuf {
    paths::appdata_dir().join("usage")
}

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn number(value: &Value, key: &str) -> u64 {
    value.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn parse_line(line: &str) -> Option<UsageEvent> {
    let value: Value = serde_json::from_str(line).ok()?;
    let at = text(&value, "at");
    if at.is_empty() {
        return None;
    }
    let id = match value.get("id").and_then(Value::as_str) {
        Some(id) if !id.is_empty() => id.to_string(),
        // Older lines may miss the dedup key; the timestamp plus the model and
        // counters identify the request closely enough for a stable row.
        _ => format!(
            "{}|{}|{}|{}|{}",
            at,
            text(&value, "model"),
            number(&value, "input"),
            number(&value, "output"),
            number(&value, "status")
        ),
    };
    Some(UsageEvent {
        id,
        at,
        model: text(&value, "model"),
        provider: text(&value, "provider"),
        auth: text(&value, "auth"),
        input: number(&value, "input"),
        output: number(&value, "output"),
        mode: text(&value, "mode"),
        status: value
            .get("status")
            .and_then(Value::as_u64)
            .unwrap_or(0)
            .min(u16::MAX as u64) as u16,
    })
}

/// Read every daily file, newest last. Unreadable files are skipped instead of
/// failing the screen: telemetry is diagnostic, never critical.
pub fn load(limit: Option<usize>) -> UsageSnapshot {
    let limit = limit.unwrap_or(DEFAULT_LIMIT).max(1);
    let mut files: Vec<PathBuf> = match fs::read_dir(dir()) {
        Ok(entries) => entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension().and_then(|ext| ext.to_str()) == Some("jsonl")
                    && path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.starts_with("usage-"))
            })
            .collect(),
        Err(_) => Vec::new(),
    };
    files.sort();

    let mut events = Vec::new();
    for path in &files {
        let Ok(contents) = fs::read_to_string(path) else {
            continue;
        };
        for line in contents.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Some(event) = parse_line(line) {
                events.push(event);
            }
        }
    }

    let total = events.len();
    let truncated = total > limit;
    if truncated {
        events.drain(..total - limit);
    }
    UsageSnapshot {
        events,
        total,
        files: files.len(),
        truncated,
    }
}

/// Removes every day file. The macOS screen offers this as an explicit
/// "Clear history" action, and the numbers are recomputed from the files, so
/// deleting them is the whole reset. Returns how many files went away.
pub fn clear() -> Result<usize, String> {
    clear_dir(&dir())
}

/// The body of `clear`, split out so a test can point it at a temp folder
/// instead of the user's real telemetry.
fn clear_dir(root: &std::path::Path) -> Result<usize, String> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        // Nothing recorded yet: clearing an empty history is not an error.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error.to_string()),
    };
    let mut removed = 0;
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        let is_day_file = path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("usage-") && name.ends_with(".jsonl"));
        if !is_day_file {
            continue;
        }
        fs::remove_file(&path).map_err(|error| error.to_string())?;
        removed += 1;
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_gateway_line() {
        let line = r#"{"at":"2026-11-22T17:27:46Z","auth":"codex-a.json","id":"1795368466|gpt|codex|132941|302|200","input":132941,"mode":"stream","model":"gpt-6.2-sol","output":302,"provider":"codex","status":200}"#;
        let event = parse_line(line).expect("line parses");
        assert_eq!(event.provider, "codex");
        assert_eq!(event.input, 132941);
        assert_eq!(event.status, 200);
        assert_eq!(event.id, "1795368466|gpt|codex|132941|302|200");
    }

    #[test]
    fn skips_lines_without_a_timestamp() {
        assert!(parse_line(r#"{"model":"gpt"}"#).is_none());
        assert!(parse_line("not json").is_none());
    }

    #[test]
    fn clear_removes_day_files_but_keeps_other_files() {
        let root = std::env::temp_dir().join(format!("melon-usage-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).expect("temp dir");
        fs::write(root.join("usage-2026-11-22.jsonl"), "{}\n").expect("write");
        fs::write(root.join("usage-2026-11-23.jsonl"), "{}\n").expect("write");
        fs::write(root.join("note.txt"), "keep").expect("write");
        assert_eq!(clear_dir(&root).expect("clear"), 2);
        assert!(!root.join("usage-2026-11-22.jsonl").exists());
        assert!(root.join("note.txt").exists());
        // A second reset on an empty folder is a no-op, not an error.
        assert_eq!(clear_dir(&root).expect("clear again"), 0);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn synthesizes_a_key_for_old_lines() {
        let event = parse_line(
            r#"{"at":"2026-11-22T17:27:46Z","model":"m","input":1,"output":2,"status":200}"#,
        )
        .expect("line parses");
        assert_eq!(event.id, "2026-11-22T17:27:46Z|m|1|2|200");
    }
}
