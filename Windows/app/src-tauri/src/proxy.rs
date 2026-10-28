//! Upstream proxy settings.
//!
//! Local loopback clients set `.no_proxy()` explicitly. External clients call
//! [`apply`], which uses the explicit URL or the Windows system proxy.

use std::sync::{OnceLock, RwLock};

use reqwest::ClientBuilder;

use crate::settings::Settings;

static ACTIVE: OnceLock<RwLock<Option<String>>> = OnceLock::new();
static BYPASS: OnceLock<RwLock<String>> = OnceLock::new();

fn slot() -> &'static RwLock<Option<String>> {
    ACTIVE.get_or_init(|| RwLock::new(None))
}

fn bypass_slot() -> &'static RwLock<String> {
    BYPASS.get_or_init(|| RwLock::new("127.0.0.1,localhost".to_string()))
}

/// Recompute the effective proxy from settings. An empty URL with the switch
/// on means "use the system proxy".
pub fn configure(settings: &Settings) {
    let value = if !settings.proxy_enabled {
        None
    } else {
        let explicit = settings.proxy_url.trim();
        if !explicit.is_empty() {
            Some(if explicit.contains("://") {
                explicit.to_string()
            } else {
                format!("http://{explicit}")
            })
        } else {
            system_proxy_url()
        }
    };
    if let Ok(mut guard) = slot().write() {
        *guard = value;
    }
    if let Ok(mut guard) = bypass_slot().write() {
        *guard = settings.proxy_bypass.clone();
    }
}

pub fn active_url() -> Option<String> {
    slot().read().ok().and_then(|guard| guard.clone())
}

pub fn engine_url() -> String {
    active_url().unwrap_or_default()
}

/// Apply the configured proxy to an external request client.
pub fn apply(builder: ClientBuilder) -> ClientBuilder {
    match active_url().and_then(|url| reqwest::Proxy::all(url).ok()) {
        Some(proxy) => {
            let bypass = bypass_slot()
                .read()
                .map(|value| value.clone())
                .unwrap_or_default();
            builder.proxy(proxy.no_proxy(reqwest::NoProxy::from_string(&bypass)))
        }
        None => builder.no_proxy(),
    }
}

/// Local gateway/CDP traffic must never go through a proxy.
pub fn local(builder: ClientBuilder) -> ClientBuilder {
    builder.no_proxy()
}

/// Best-effort system proxy discovery. On Windows this reads the per-user
/// Internet Settings (the same values WinHTTP/Edge use). PAC URLs are not
/// resolved here; an explicit proxy URL covers those setups.
pub fn system_proxy_url() -> Option<String> {
    #[cfg(windows)]
    {
        let output = std::process::Command::new("reg")
            .args([
                "query",
                r"HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings",
            ])
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        let mut enabled = false;
        let mut server = None;
        for line in text.lines() {
            let lower = line.to_ascii_lowercase();
            if lower.contains("proxyenable") {
                enabled = line.to_ascii_lowercase().contains("0x1");
            } else if lower.contains("proxyserver") {
                server = line.split_whitespace().last().map(String::from);
            }
        }
        if enabled {
            return server.and_then(|value| normalize_proxy_server(&value));
        }
        None
    }
    #[cfg(not(windows))]
    {
        for key in [
            "HTTPS_PROXY",
            "https_proxy",
            "HTTP_PROXY",
            "http_proxy",
            "ALL_PROXY",
            "all_proxy",
        ] {
            if let Ok(value) = std::env::var(key) {
                let value = value.trim();
                if !value.is_empty() {
                    return Some(value.to_string());
                }
            }
        }
        None
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
fn normalize_proxy_server(server: &str) -> Option<String> {
    // ProxyServer is either "host:port" or "http=host:port;https=host:port".
    if server.contains('=') {
        let mut chosen: Option<(String, &str)> = None;
        for part in server.split(';') {
            let Some((kind, value)) = part.split_once('=') else {
                continue;
            };
            let kind = kind.trim().to_ascii_lowercase();
            if value.trim().is_empty() {
                continue;
            }
            if kind == "https" || (chosen.is_none() && (kind == "http" || kind == "socks")) {
                chosen = Some((kind, value.trim()));
            }
        }
        let (kind, value) = chosen?;
        let value = value.trim();
        if value.contains("://") {
            return Some(value.to_string());
        }
        return Some(format!(
            "{}://{}",
            if kind == "socks" { "socks5" } else { "http" },
            value
        ));
    }
    let value = server.trim();
    if value.is_empty() {
        None
    } else if value.contains("://") {
        Some(value.to_string())
    } else {
        Some(format!("http://{value}"))
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_proxy_server;

    #[test]
    fn bare_proxy_server_becomes_http() {
        assert_eq!(
            normalize_proxy_server("127.0.0.1:7890").as_deref(),
            Some("http://127.0.0.1:7890")
        );
    }

    #[test]
    fn per_scheme_proxy_server_prefers_https() {
        assert_eq!(
            normalize_proxy_server("http=proxy:8080;https=secure:8443").as_deref(),
            Some("http://secure:8443")
        );
    }

    #[test]
    fn socks_proxy_server_keeps_socks_scheme() {
        assert_eq!(
            normalize_proxy_server("socks=127.0.0.1:1080").as_deref(),
            Some("socks5://127.0.0.1:1080")
        );
    }
}
