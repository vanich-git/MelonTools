//! Browser OAuth login: PKCE + loopback redirect, the same flow the official
//! Codex CLI uses. Ported from `CodexStore.startBrowserLogin` (macOS).
//!
//! The renderer starts a session, opens the returned URL in the default
//! browser, then polls `browser_login_status`. The loopback server lives in
//! this module: it answers exactly one `/auth/callback` request, hands the code
//! over to the waiting task and shuts down, so no listener outlives a login.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use base64::Engine as _;
use rand::RngCore;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::device_login;
use crate::vault;

const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const AUTHORIZE_ENDPOINT: &str = "https://auth.openai.com/oauth/authorize";
const BROWSER_SCOPE: &str = "openid profile email offline_access";
/// How long a pending login stays pollable before it is reported as stale.
const SESSION_TTL_SECS: u64 = 600;

struct Session {
    id: String,
    port: u16,
    created_at: u64,
    status: String,
    error: Option<String>,
    account: Option<String>,
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn random_b64(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut buf);
    b64url(&buf)
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// PKCE verifier/challenge (S256) + state, mirroring `CodexService.makePKCE`.
fn make_pkce() -> (String, String, String) {
    let verifier = random_b64(32);
    let challenge = b64url(Sha256::digest(verifier.as_bytes()).as_slice());
    let state = random_b64(16);
    (verifier, challenge, state)
}

fn authorization_url(challenge: &str, state: &str, redirect_uri: &str) -> String {
    let query = [
        ("client_id", CLIENT_ID),
        ("response_type", "code"),
        ("redirect_uri", redirect_uri),
        ("scope", BROWSER_SCOPE),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
        ("state", state),
        ("id_token_add_organizations", "true"),
        ("codex_cli_simplified_flow", "true"),
        ("originator", "codex_cli_rs"),
    ]
    .iter()
    .map(|(key, value)| format!("{}={}", key, urlencoding(value)))
    .collect::<Vec<_>>()
    .join("&");
    format!("{AUTHORIZE_ENDPOINT}?{query}")
}

/// Minimal percent-encoding for query values: everything outside the
/// unreserved set is escaped, which keeps base64url and URLs intact.
fn urlencoding(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            b':' | b'/' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// One login at a time: a second start replaces the previous pending session.
static SESSION: Mutex<Option<Session>> = Mutex::new(None);
static GENERATION: AtomicU64 = AtomicU64::new(0);

fn set_session(session: Option<Session>) {
    if let Ok(mut guard) = SESSION.lock() {
        *guard = session;
    }
}

/// Reads the request path of a raw HTTP request head and returns the `code`
/// and `state` query values of `/auth/callback`.
fn parse_callback(request: &str) -> Option<(String, String)> {
    let line = request.lines().next()?;
    let mut parts = line.split_whitespace();
    let _method = parts.next()?;
    let target = parts.next()?;
    if !target.starts_with("/auth/callback") {
        return None;
    }
    let query = target.split_once('?').map(|(_, query)| query).unwrap_or("");
    let mut code = None;
    let mut state = None;
    for pair in query.split('&') {
        let (key, value) = pair.split_once('=')?;
        let decoded = decode_component(value);
        match key {
            "code" => code = Some(decoded),
            "state" => state = Some(decoded),
            _ => {}
        }
    }
    Some((code?, state?))
}

/// Percent-decoding for the callback values; `+` is a space in a form body.
fn decode_component(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'%' if index + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
                match hex.and_then(|hex| u8::from_str_radix(hex, 16).ok()) {
                    Some(byte) => {
                        out.push(byte);
                        index += 3;
                    }
                    None => {
                        out.push(bytes[index]);
                        index += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                index += 1;
            }
            byte => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

fn respond(stream: &mut std::net::TcpStream, status: &str, body: &str) {
    use std::io::Write;
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(reply.as_bytes());
    let _ = stream.flush();
}

/// Starts a browser login: binds the loopback port, spawns the exchange task
/// and returns the authorize URL plus the session id the UI polls with.
pub fn start() -> Result<Value, String> {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0))
        .map_err(|e| format!("не удалось открыть loopback-порт: {e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let (verifier, challenge, state) = make_pkce();
    let redirect = format!("http://localhost:{port}/auth/callback");
    let url = authorization_url(&challenge, &state, &redirect);
    let id = random_b64(9);
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;

    set_session(Some(Session {
        id: id.clone(),
        port,
        created_at: now_secs(),
        status: "waiting".to_string(),
        error: None,
        account: None,
    }));

    let session_id = id.clone();
    let redirect_for_task = redirect.clone();
    tauri::async_runtime::spawn(async move {
        let outcome = run_login(listener, verifier, state, redirect_for_task, generation).await;
        if GENERATION.load(Ordering::SeqCst) != generation {
            return;
        }
        if let Ok(mut guard) = SESSION.lock() {
            if let Some(session) = guard.as_mut().filter(|session| session.id == session_id) {
                match outcome {
                    Ok(account) => {
                        session.status = "done".to_string();
                        session.account = Some(account);
                    }
                    Err(error) => {
                        session.status = "error".to_string();
                        session.error = Some(error);
                    }
                }
            }
        }
    });

    Ok(json!({
        "id": id,
        "url": url,
        "redirectURI": redirect,
        "port": port,
        "expiresAt": now_secs() + SESSION_TTL_SECS,
    }))
}

/// Accepts the single callback request, then exchanges the code for tokens.
async fn run_login(
    listener: std::net::TcpListener,
    verifier: String,
    expected_state: String,
    redirect: String,
    generation: u64,
) -> Result<String, String> {
    // Blocking accept on its own thread: the renderer polls, so a stalled
    // browser must not hold a runtime worker.
    let accepted = tauri::async_runtime::spawn_blocking(move || -> Result<String, String> {
        listener.set_nonblocking(false).map_err(|e| e.to_string())?;
        let mut pending: Option<(String, String)> = None;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(SESSION_TTL_SECS);
        while std::time::Instant::now() < deadline {
            let (mut stream, _) = match listener.accept() {
                Ok(pair) => pair,
                Err(error) => return Err(error.to_string()),
            };
            let mut head = [0u8; 4096];
            let read = std::io::Read::read(&mut stream, &mut head).unwrap_or(0);
            let request = String::from_utf8_lossy(&head[..read]).to_string();
            match parse_callback(&request) {
                Some((code, state)) if state == expected_state => {
                    respond(
                        &mut stream,
                        "200 OK",
                        "<h1>Melon Tools</h1><p>Можно закрыть вкладку.</p>",
                    );
                    pending = Some((code, state));
                    break;
                }
                Some(_) => {
                    respond(&mut stream, "400 Bad Request", "state mismatch");
                }
                None => {
                    respond(&mut stream, "404 Not Found", "not found");
                }
            }
        }
        pending
            .map(|(code, _)| code)
            .ok_or_else(|| "браузер не вернул код авторизации".to_string())
    })
    .await
    .map_err(|e| e.to_string())??;

    if GENERATION.load(Ordering::SeqCst) != generation {
        return Err("вход отменён".to_string());
    }
    let client = crate::quota::client()?;
    let tokens = device_login::exchange_code(&client, &accepted, &verifier, &redirect).await?;
    if GENERATION.load(Ordering::SeqCst) != generation {
        return Err("вход отменён".to_string());
    }
    let account = vault::upsert_from_tokens(&tokens)?;
    Ok(account)
}

/// Pollable state of the current login attempt. An expired session reports
/// `timeout` instead of waiting forever in the UI.
pub fn status() -> Value {
    let guard = SESSION.lock().ok();
    let snapshot = guard.as_ref().and_then(|guard| guard.as_ref());
    match snapshot {
        None => json!({ "status": "idle" }),
        Some(session) => {
            let expired = now_secs().saturating_sub(session.created_at) >= SESSION_TTL_SECS;
            let status = if session.status == "waiting" && expired {
                "timeout"
            } else {
                session.status.as_str()
            };
            json!({
                "id": session.id,
                "status": status,
                "port": session.port,
                "error": session.error,
                "account": session.account,
            })
        }
    }
}

/// Drops the pending session: the loopback task gives up on its next check.
pub fn cancel() {
    GENERATION.fetch_add(1, Ordering::SeqCst);
    set_session(None);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_verifier_is_url_safe_and_challenge_is_sha256() {
        let (verifier, challenge, state) = make_pkce();
        assert!(!verifier.contains('+'));
        assert!(!verifier.contains('/'));
        assert!(!verifier.contains('='));
        assert_eq!(verifier.len(), 43);
        assert_eq!(state.len(), 22);
        assert_eq!(
            challenge,
            b64url(Sha256::digest(verifier.as_bytes()).as_slice())
        );
    }

    #[test]
    fn authorize_url_carries_pkce_and_simplified_flow() {
        let url = authorization_url("CH", "ST", "http://localhost:1234/auth/callback");
        assert!(url.starts_with("https://auth.openai.com/oauth/authorize?"));
        assert!(url.contains("code_challenge=CH"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("state=ST"));
        assert!(url.contains("redirect_uri=http://localhost:1234/auth/callback"));
        assert!(url.contains("codex_cli_simplified_flow=true"));
        assert!(url.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"));
    }

    #[test]
    fn callback_parses_code_and_state() {
        let request =
            "GET /auth/callback?code=abc-123&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n";
        let (code, state) = parse_callback(request).expect("callback");
        assert_eq!(code, "abc-123");
        assert_eq!(state, "xyz");
    }

    #[test]
    fn callback_rejects_other_paths_and_decodes_escapes() {
        assert!(parse_callback("GET /favicon.ico HTTP/1.1\r\n\r\n").is_none());
        // Percent escapes and a raw `+` both arrive from a browser form post.
        let request = "GET /auth/callback?code=a%2Fb%2Bc+d&state=s%20t HTTP/1.1\r\n\r\n";
        let (code, state) = parse_callback(request).expect("callback");
        assert_eq!(code, "a/b+c d");
        assert_eq!(state, "s t");
    }

    #[test]
    fn status_without_session_is_idle() {
        cancel();
        assert_eq!(status()["status"], "idle");
    }
}
