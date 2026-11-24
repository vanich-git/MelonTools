//! One link, from the outside world to a page and a tab.
//!
//! A shortcut, a script or a second launch can ask the app to open a specific
//! screen. The mapping lives here so the startup path, the single-instance
//! callback and the JS side agree on the same names.

use serde::Serialize;

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub section: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tab: Option<String>,
}

/// Sections the UI can render. A typo must not leave the window on a blank
/// page, so an unknown name is dropped instead of forwarded.
const SECTIONS: &[&str] = &[
    "dashboard",
    "agents",
    "routing",
    "providers",
    "local_ai",
    "usage",
    "scheduler",
    "accounts",
    "settings",
    "donate",
];

/// Tabs of the merged routing page.
const TABS: &[(&str, &str)] = &[
    ("routing", "routing"),
    ("api", "api"),
    ("api-service", "api"),
    ("apiservice", "api"),
    ("codex-api", "api"),
    ("codexapi", "api"),
];

fn normalize(value: &str) -> String {
    value
        .trim()
        .trim_matches('/')
        .to_lowercase()
        .replace('-', "_")
}

/// Parses `melon://routing/api`, `melon:routing`, or the command line
/// spellings `--section=routing --tab=api`. Everything unrecognised yields
/// `None`, so a stray argument never navigates anywhere.
pub fn parse(raw: &str) -> Option<Target> {
    let text = raw.trim();
    if text.is_empty() {
        return None;
    }
    // A scheme is case-insensitive and Windows may hand over either spelling.
    let lowered = text.to_ascii_lowercase();
    let prefix_len = if lowered.starts_with("melon://") {
        8
    } else if lowered.starts_with("melon:") {
        6
    } else if lowered.starts_with("--open=") {
        7
    } else if text.starts_with("--") {
        2
    } else {
        0
    };
    let rest = &text[prefix_len..];
    let body = rest;
    // Path separators and query separators both split the link; a command
    // line may also use spaces between the same key=value pairs.
    let mut parts = body
        .split(|c: char| matches!(c, '/' | '?' | '&') || c.is_whitespace())
        .filter(|p| !p.is_empty());
    let head = parts.next()?;
    // `section=routing` / `tab=api` keep the same parser.
    let (first_key, first_value) = match head.split_once('=') {
        Some((key, value)) => (key, value),
        None => ("", head),
    };
    let mut section = None;
    let mut tab = None;
    if first_key.is_empty() || first_key.eq_ignore_ascii_case("section") {
        section = Some(normalize(first_value));
    } else if first_key.eq_ignore_ascii_case("tab") {
        tab = Some(normalize(first_value));
    }
    for part in parts {
        let part = part.trim_start_matches('-');
        match part.split_once('=') {
            Some((key, value)) if key.eq_ignore_ascii_case("tab") => tab = Some(normalize(value)),
            Some((key, value)) if key.eq_ignore_ascii_case("section") => {
                section = Some(normalize(value))
            }
            // `melon://routing/api` names the tab as a second path segment.
            _ if tab.is_none() => tab = Some(normalize(part)),
            _ => {}
        }
    }
    let section = section?;
    // The API service is a tab of Routing now: a link to it opens that page.
    if matches!(
        section.as_str(),
        "codex_api" | "codexapi" | "api" | "apiservice"
    ) {
        return Some(Target {
            section: "routing".to_string(),
            tab: Some("api".to_string()),
        });
    }
    let section = match section.as_str() {
        "local_ai" | "localai" => "local_ai",
        other => other,
    };
    if !SECTIONS.contains(&section) {
        return None;
    }
    let section = section.to_string();
    let tab = tab.and_then(|name| {
        TABS.iter()
            .find(|(alias, _)| *alias == name)
            .map(|(_, tab)| tab.to_string())
    });
    Some(Target { section, tab })
}

/// First recognised link among the process arguments.
pub fn from_args<I: IntoIterator<Item = String>>(args: I) -> Option<Target> {
    args.into_iter().skip(1).find_map(|arg| parse(&arg))
}

/// `melon://` as a real Windows protocol handler.
///
/// The portable build has no installer to write these keys, so registration
/// runs on every start and is idempotent. Only `HKEY_CURRENT_USER` is touched:
/// a per-user app must not ask for elevation, and uninstalling the per-user
/// installer removes the same keys.
#[cfg(windows)]
pub fn register_protocol() {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::System::Registry::{
        RegCloseKey, RegCreateKeyExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_WRITE,
        REG_OPTION_NON_VOLATILE, REG_SZ,
    };

    fn wide(text: &str) -> Vec<u16> {
        std::ffi::OsStr::new(text)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    /// Creates one key and writes a single string value into it.
    unsafe fn write(key: &str, name: &str, value: &str) -> bool {
        let mut handle: HKEY = std::ptr::null_mut();
        let subkey = wide(key);
        let created = RegCreateKeyExW(
            HKEY_CURRENT_USER,
            subkey.as_ptr(),
            0,
            std::ptr::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            std::ptr::null(),
            &mut handle,
            std::ptr::null_mut(),
        );
        if created != ERROR_SUCCESS {
            return false;
        }
        let value_name = wide(name);
        let bytes = wide(value);
        let size = (bytes.len() * std::mem::size_of::<u16>()) as u32;
        let written = RegSetValueExW(
            handle,
            value_name.as_ptr(),
            0,
            REG_SZ,
            bytes.as_ptr() as *const u8,
            size,
        );
        RegCloseKey(handle);
        written == ERROR_SUCCESS
    }

    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let exe = exe.to_string_lossy().to_string();
    let base = "Software\\Classes\\melon";
    // SAFETY: every pointer comes from a local wide buffer that outlives the
    // call, and the returned handle is closed on both paths.
    unsafe {
        write(base, "", "URL:Melon Tools Protocol");
        write(base, "URL Protocol", "");
        write(&format!("{base}\\DefaultIcon"), "", &format!("{exe},0"));
        write(
            &format!("{base}\\shell\\open\\command"),
            "",
            &format!("\"{exe}\" \"%1\""),
        );
    }
}

#[cfg(not(windows))]
pub fn register_protocol() {}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(section: &str, tab: Option<&str>) -> Target {
        Target {
            section: section.to_string(),
            tab: tab.map(str::to_string),
        }
    }

    #[test]
    fn scheme_links_open_a_section() {
        assert_eq!(parse("melon://usage"), Some(target("usage", None)));
        assert_eq!(parse("melon:settings"), Some(target("settings", None)));
        assert_eq!(parse("MELON://Agents"), Some(target("agents", None)));
        assert_eq!(parse("melon://local-ai"), Some(target("local_ai", None)));
    }

    #[test]
    fn api_links_land_on_the_routing_tab() {
        assert_eq!(
            parse("melon://routing/api"),
            Some(target("routing", Some("api")))
        );
        assert_eq!(parse("melon://api"), Some(target("routing", Some("api"))));
        assert_eq!(
            parse("--tab=api --section=routing"),
            Some(target("routing", Some("api")))
        );
        assert_eq!(
            parse("melon://routing?tab=api"),
            Some(target("routing", Some("api")))
        );
    }

    #[test]
    fn unknown_names_navigate_nowhere() {
        assert_eq!(parse(""), None);
        assert_eq!(parse("melon://nope"), None);
        assert_eq!(parse("--verbose"), None);
        // A known section with an unknown tab still opens the page.
        assert_eq!(parse("melon://usage/whatever"), Some(target("usage", None)));
    }

    #[test]
    fn arguments_are_scanned_past_the_executable() {
        let args = vec![
            "melon.exe".to_string(),
            "--restore-codex-route".to_string(),
            "melon://scheduler".to_string(),
        ];
        assert_eq!(from_args(args), Some(target("scheduler", None)));
    }
}
