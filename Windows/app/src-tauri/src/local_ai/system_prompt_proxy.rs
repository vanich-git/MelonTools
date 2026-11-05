//! Loopback relay that applies each model's stored system prompt to the
//! requests it serves.
//!
//! llama.cpp's router reads its per-model options from `models.ini` and has no
//! "system prompt" option, so the only place a per-model prompt can reach every
//! client is the request body. The gateway is pointed at this listener instead
//! of the router: Chat Completions and Responses bodies get the prompt merged
//! in, every other request is relayed byte for byte.
//!
//! One request per connection: the relay always answers with
//! `Connection: close`, which keeps the response framing simple at the cost of
//! a reconnect per call — irrelevant on loopback.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

/// Port the listener is bound to; 0 while it is not running.
static PORT: AtomicU16 = AtomicU16::new(0);
/// Router the relay forwards to. llama.cpp picks a free port on every launch,
/// so the engine updates this each time it starts.
static UPSTREAM: AtomicU16 = AtomicU16::new(0);
static START_LOCK: Mutex<()> = Mutex::new(());

const MAX_BODY: usize = 64 << 20;
/// Long enough for a slow model to stream a whole answer.
const IO_TIMEOUT_SECS: u64 = 600;

/// Binds the relay once and returns its port, 0 when it cannot bind.
///
/// The port ends up in the gateway config, so a restart would leave the config
/// pointing at a dead socket; an already running relay therefore just reports
/// its port.
pub fn ensure_started() -> u16 {
    let running = PORT.load(Ordering::SeqCst);
    if running != 0 {
        return running;
    }

    let _guard = START_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let running = PORT.load(Ordering::SeqCst);
    if running != 0 {
        return running;
    }

    let listener = match TcpListener::bind(("127.0.0.1", 0)) {
        Ok(listener) => listener,
        Err(_) => return 0,
    };
    let port = match listener.local_addr() {
        Ok(addr) => addr.port(),
        Err(_) => return 0,
    };
    if UPSTREAM.load(Ordering::SeqCst) == 0 {
        UPSTREAM.store(super::local_runtime::get_runtime_port(), Ordering::SeqCst);
    }
    let spawned = std::thread::Builder::new()
        .name("system-prompt-relay".to_string())
        .spawn(move || accept_loop(listener));
    if spawned.is_err() {
        // Advertising a port with no listener would break every local call
        // with a connection error instead of a clean fallback to the router.
        return 0;
    }
    PORT.store(port, Ordering::SeqCst);
    port
}

/// Router the relay forwards to; called by the engine on every launch.
pub fn set_upstream(port: u16) {
    UPSTREAM.store(port, Ordering::SeqCst);
}

/// Port the gateway must advertise for local models: the relay when it can
/// bind, the router itself otherwise.
pub fn published_port(fallback: u16) -> u16 {
    match ensure_started() {
        0 => fallback,
        relay => relay,
    }
}

// MARK: - Prompt plumbing

/// Request paths whose body carries a conversation the prompt belongs in.
pub(crate) fn is_rewritable(path: &str) -> bool {
    let path = path.split('?').next().unwrap_or(path);
    path == "/v1/chat/completions" || path == "/v1/responses"
}

/// Model id from an OpenAI-style body; `None` when there is nothing to look up
/// (the relay then forwards the request untouched).
pub(crate) fn model_id(body: &[u8]) -> Option<String> {
    let value: Value = serde_json::from_slice(body).ok()?;
    value.get("model")?.as_str().map(str::to_string)
}

/// Merges `prompt` into the body. Chat Completions gets it as — or merged into
/// — the leading system message; Responses gets it into `instructions`.
/// Returns None when the body is not shaped the way the endpoint promises, so
/// the caller relays the original bytes.
pub(crate) fn merge(prompt: &str, path: &str, body: &[u8]) -> Option<Vec<u8>> {
    let prompt = prompt.trim();
    if prompt.is_empty() {
        return None;
    }
    let mut value: Value = serde_json::from_slice(body).ok()?;

    if path.ends_with("/chat/completions") {
        let messages = value.get_mut("messages")?.as_array_mut()?;
        if messages.is_empty() {
            return None;
        }
        let first_is_system = messages[0].get("role").and_then(Value::as_str) == Some("system");
        if first_is_system {
            if let Some(existing) = messages[0].get("content").and_then(Value::as_str) {
                // Merge into the existing message: some chat templates only
                // render the first system message, so a second one would be
                // silently dropped by the model.
                let merged = if existing.is_empty() {
                    prompt.to_string()
                } else {
                    format!("{prompt}\n\n{existing}")
                };
                messages[0]["content"] = Value::String(merged);
            } else {
                // Content parts (vision): keep them and add the prompt as its
                // own leading message instead of rewriting the parts.
                messages.insert(0, json!({ "role": "system", "content": prompt }));
            }
        } else {
            messages.insert(0, json!({ "role": "system", "content": prompt }));
        }
    } else if path.ends_with("/responses") {
        match value.get("instructions").cloned() {
            None | Some(Value::Null) => {
                value["instructions"] = Value::String(prompt.to_string());
            }
            Some(Value::String(existing)) => {
                let merged = if existing.is_empty() {
                    prompt.to_string()
                } else {
                    format!("{prompt}\n\n{existing}")
                };
                value["instructions"] = Value::String(merged);
            }
            // Some other shape (array of parts) — leave it alone rather than
            // corrupt a request we do not understand.
            Some(_) => return None,
        }
    } else {
        return None;
    }

    serde_json::to_vec(&value).ok()
}

/// Reads one model's stored prompt straight from the registry file: the store
/// parses GGUF headers on load, which is far too much work per request, and the
/// registry JSON is what the settings dialog actually wrote.
fn prompt_for(model_id: &str) -> Option<String> {
    let data = std::fs::read_to_string(crate::paths::models_registry_path()).ok()?;
    let entries: Vec<Value> = serde_json::from_str(&data).ok()?;
    let wanted = canonical_model_id(model_id);
    let entry = entries.into_iter().find(|entry| {
        entry
            .get("id")
            .and_then(Value::as_str)
            .map(canonical_model_id)
            == Some(wanted.clone())
    })?;
    let prompt = entry
        .get("userSettings")?
        .get("systemPrompt")?
        .as_str()?
        .trim()
        .to_string();
    (!prompt.is_empty()).then_some(prompt)
}

/// Clients may address a local model by its `local/` alias.
fn canonical_model_id(id: &str) -> String {
    id.strip_prefix("local/").unwrap_or(id).to_string()
}

// MARK: - Connection handling

fn accept_loop(listener: TcpListener) {
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                let _ = std::thread::Builder::new()
                    .name("system-prompt-relay-conn".to_string())
                    .spawn(move || handle(stream));
            }
            Err(error) => {
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                // The listener is never closed, so anything else here is
                // transient; a wedged accept would otherwise kill the relay
                // for the rest of the session.
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

fn handle(client: TcpStream) {
    handle_with(client, UPSTREAM.load(Ordering::SeqCst), prompt_for);
}

/// One request/response exchange. Split from `handle` so the socket path can be
/// exercised without the globals (and without the real registry).
fn handle_with<F>(mut client: TcpStream, upstream: u16, prompt_for: F)
where
    F: Fn(&str) -> Option<String>,
{
    let _ = client.set_read_timeout(Some(Duration::from_secs(IO_TIMEOUT_SECS)));
    let _ = client.set_write_timeout(Some(Duration::from_secs(IO_TIMEOUT_SECS)));

    let Ok(source) = client.try_clone() else {
        return;
    };
    let mut reader = Reader::new(source);
    let Some(request) = read_request(&mut reader) else {
        return;
    };

    if upstream == 0 {
        respond_plain(
            &mut client,
            "503 Service Unavailable",
            "Local engine is not running.",
        );
        return;
    }

    let mut body = request.body.clone();
    if request.method == "POST" && is_rewritable(&request.target) {
        if let Some(model) = model_id(&body) {
            if let Some(prompt) = prompt_for(&model) {
                if let Some(rewritten) = merge(&prompt, &request.target, &body) {
                    body = rewritten;
                }
            }
        }
    }

    let Ok(mut upstream_stream) = TcpStream::connect(("127.0.0.1", upstream)) else {
        respond_plain(
            &mut client,
            "502 Bad Gateway",
            "Local engine is not reachable.",
        );
        return;
    };
    let _ = upstream_stream.set_read_timeout(Some(Duration::from_secs(IO_TIMEOUT_SECS)));
    let _ = upstream_stream.set_write_timeout(Some(Duration::from_secs(IO_TIMEOUT_SECS)));

    let head = build_request_head(&request, body.len(), upstream);
    if upstream_stream.write_all(head.as_bytes()).is_err() {
        return;
    }
    if !body.is_empty() && upstream_stream.write_all(&body).is_err() {
        return;
    }
    let _ = upstream_stream.flush();

    let mut upstream_reader = Reader::new(upstream_stream);
    relay_response(&mut upstream_reader, &mut client);
}

// MARK: - HTTP parsing

struct Request {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

fn read_request(reader: &mut Reader) -> Option<Request> {
    let head = String::from_utf8_lossy(&reader.take_head()?).to_string();
    let mut lines = head.split("\r\n");
    let request_line = lines.next()?;
    let mut parts = request_line.split(' ');
    let method = parts.next()?.to_string();
    let target = parts.next()?.to_string();
    parts.next()?;

    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.push((name.trim().to_ascii_lowercase(), value.trim().to_string()));
        }
    }

    let body = read_body(reader, &headers);
    Some(Request {
        method,
        target,
        headers,
        body,
    })
}

fn read_body(reader: &mut Reader, headers: &[(String, String)]) -> Vec<u8> {
    if let Some(value) = header(headers, "transfer-encoding") {
        if value.to_ascii_lowercase().contains("chunked") {
            return read_chunked(reader);
        }
    }
    if let Some(length) =
        header(headers, "content-length").and_then(|value| value.parse::<usize>().ok())
    {
        if length > 0 && length <= MAX_BODY {
            return reader.take(length).unwrap_or_default();
        }
    }
    Vec::new()
}

fn read_chunked(reader: &mut Reader) -> Vec<u8> {
    let mut body = Vec::new();
    while body.len() <= MAX_BODY {
        let Some(line) = reader.take_line() else {
            return body;
        };
        let text = String::from_utf8_lossy(&line).to_string();
        let size_text = text.split(';').next().unwrap_or(&text).trim().to_string();
        let Ok(size) = usize::from_str_radix(&size_text, 16) else {
            return body;
        };
        if size == 0 {
            // Trailers, if any, end with an empty line.
            while let Some(trailer) = reader.take_line() {
                if trailer.is_empty() {
                    break;
                }
            }
            return body;
        }
        let Some(chunk) = reader.take(size) else {
            return body;
        };
        body.extend_from_slice(&chunk);
        let _ = reader.take_line();
    }
    body
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(header_name, _)| header_name.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

fn build_request_head(request: &Request, body_length: usize, upstream: u16) -> String {
    // Framing and hop-by-hop headers are ours to decide: the body may have been
    // rewritten, and one request per connection keeps the relay simple.
    const DROPPED: [&str; 8] = [
        "content-length",
        "transfer-encoding",
        "connection",
        "keep-alive",
        "proxy-connection",
        "expect",
        "upgrade",
        "host",
    ];
    let mut out = format!("{} {} HTTP/1.1\r\n", request.method, request.target);
    for (name, value) in &request.headers {
        if DROPPED.contains(&name.as_str()) {
            continue;
        }
        out.push_str(&format!("{name}: {value}\r\n"));
    }
    out.push_str(&format!("Host: 127.0.0.1:{upstream}\r\n"));
    out.push_str(&format!("Content-Length: {body_length}\r\n"));
    out.push_str("Connection: close\r\n\r\n");
    out
}

// MARK: - Response relay

fn relay_response(upstream: &mut Reader, client: &mut TcpStream) {
    let Some(head) = upstream.take_head() else {
        return;
    };
    let head = String::from_utf8_lossy(&head).to_string();
    let mut lines = head.split("\r\n");
    let Some(status_line) = lines.next() else {
        return;
    };

    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.push((name.trim().to_string(), value.trim().to_string()));
        }
    }

    // The client asked for a keep-alive connection; this relay closes after one
    // exchange, and saying so is cheaper than framing every response.
    let mut rewritten = format!("{status_line}\r\n");
    const HOP_BY_HOP: [&str; 3] = ["connection", "keep-alive", "proxy-connection"];
    for (name, value) in &headers {
        if HOP_BY_HOP.contains(&name.to_ascii_lowercase().as_str()) {
            continue;
        }
        rewritten.push_str(&format!("{name}: {value}\r\n"));
    }
    rewritten.push_str("Connection: close\r\n\r\n");
    if client.write_all(rewritten.as_bytes()).is_err() {
        return;
    }

    let chunked = headers.iter().any(|(name, value)| {
        name.eq_ignore_ascii_case("transfer-encoding")
            && value.to_ascii_lowercase().contains("chunked")
    });
    if chunked {
        relay_chunked(upstream, client);
    } else if let Some(length) =
        header(&headers, "content-length").and_then(|value| value.parse::<usize>().ok())
    {
        relay_body(upstream, client, length);
    } else {
        relay_to_eof(upstream, client);
    }
}

fn relay_chunked(upstream: &mut Reader, client: &mut TcpStream) {
    loop {
        let Some(line) = upstream.take_line() else {
            return;
        };
        if client.write_all(&line).is_err() || client.write_all(b"\r\n").is_err() {
            return;
        }
        let text = String::from_utf8_lossy(&line).to_string();
        let size_text = text.split(';').next().unwrap_or(&text).trim().to_string();
        let Ok(size) = usize::from_str_radix(&size_text, 16) else {
            return;
        };
        if size == 0 {
            // Trailers, if any, end with an empty line.
            while let Some(trailer) = upstream.take_line() {
                let empty = trailer.is_empty();
                if client.write_all(&trailer).is_err()
                    || client.write_all(b"\r\n").is_err()
                    || empty
                {
                    return;
                }
            }
            return;
        }
        let Some(chunk) = upstream.take(size) else {
            return;
        };
        if client.write_all(&chunk).is_err() {
            return;
        }
        let Some(terminator) = upstream.take_line() else {
            return;
        };
        if client.write_all(&terminator).is_err() || client.write_all(b"\r\n").is_err() {
            return;
        }
    }
}

fn relay_body(upstream: &mut Reader, client: &mut TcpStream, length: usize) {
    let mut remaining = length;
    while remaining > 0 {
        let step = remaining.min(16_384);
        let Some(chunk) = upstream.take(step) else {
            return;
        };
        if client.write_all(&chunk).is_err() {
            return;
        }
        remaining -= chunk.len();
    }
}

fn relay_to_eof(upstream: &mut Reader, client: &mut TcpStream) {
    while let Some(chunk) = upstream.take_up_to(16_384) {
        if chunk.is_empty() || client.write_all(&chunk).is_err() {
            return;
        }
    }
}

fn respond_plain(client: &mut TcpStream, status: &str, message: &str) {
    let body = json!({ "error": { "message": message } }).to_string();
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = client.write_all(head.as_bytes());
    let _ = client.write_all(body.as_bytes());
}

// MARK: - Buffered socket reader

/// Buffered reader over a socket. Everything the relay needs — headers,
/// Content-Length bodies, chunked bodies — goes through it, so a partially read
/// buffer never loses bytes between parsing steps.
struct Reader {
    stream: TcpStream,
    buffer: Vec<u8>,
    eof: bool,
}

impl Reader {
    fn new(stream: TcpStream) -> Self {
        Self {
            stream,
            buffer: Vec::new(),
            eof: false,
        }
    }

    fn fill(&mut self) -> bool {
        if self.eof {
            return false;
        }
        let mut chunk = [0u8; 16_384];
        match self.stream.read(&mut chunk) {
            Ok(0) | Err(_) => {
                self.eof = true;
                false
            }
            Ok(count) => {
                self.buffer.extend_from_slice(&chunk[..count]);
                true
            }
        }
    }

    fn take(&mut self, count: usize) -> Option<Vec<u8>> {
        while self.buffer.len() < count {
            if !self.fill() {
                return None;
            }
        }
        let rest = self.buffer.split_off(count);
        Some(std::mem::replace(&mut self.buffer, rest))
    }

    fn take_up_to(&mut self, count: usize) -> Option<Vec<u8>> {
        if self.buffer.is_empty() && !self.fill() {
            return None;
        }
        let size = count.min(self.buffer.len());
        let rest = self.buffer.split_off(size);
        Some(std::mem::replace(&mut self.buffer, rest))
    }

    fn take_line(&mut self) -> Option<Vec<u8>> {
        loop {
            if let Some(index) = find(&self.buffer, b"\r\n") {
                let line = self.buffer[..index].to_vec();
                self.buffer.drain(..index + 2);
                return Some(line);
            }
            if !self.fill() {
                return None;
            }
        }
    }

    fn take_head(&mut self) -> Option<Vec<u8>> {
        loop {
            if let Some(index) = find(&self.buffer, b"\r\n\r\n") {
                let head = self.buffer[..index + 4].to_vec();
                self.buffer.drain(..index + 4);
                return Some(head);
            }
            if !self.fill() {
                return None;
            }
        }
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chat(messages: Value) -> Vec<u8> {
        serde_json::to_vec(&json!({ "model": "local/test", "messages": messages })).unwrap()
    }

    fn messages(body: &[u8]) -> Vec<Value> {
        let value: Value = serde_json::from_slice(body).unwrap();
        value["messages"].as_array().unwrap().clone()
    }

    /// Most chat templates render only the first system message, so a prompt
    /// with no client system message has to become the leading one.
    #[test]
    fn prompt_leads_when_client_sends_no_system_message() {
        let body = chat(json!([{ "role": "user", "content": "hi" }]));
        let merged = merge("You are terse.", "/v1/chat/completions", &body).unwrap();
        let result = messages(&merged);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0]["role"], json!("system"));
        assert_eq!(result[0]["content"], json!("You are terse."));
        assert_eq!(result[1]["role"], json!("user"));
    }

    /// A client that already carries instructions keeps them: the stored prompt
    /// is merged into the same message instead of replacing or shadowing it.
    #[test]
    fn prompt_merges_into_client_system_message() {
        let body = chat(json!([
            { "role": "system", "content": "Always answer in Russian." },
            { "role": "user", "content": "hi" },
        ]));
        let merged = merge("You are terse.", "/v1/chat/completions", &body).unwrap();
        let result = messages(&merged);
        assert_eq!(result.len(), 2);
        assert_eq!(
            result[0]["content"],
            json!("You are terse.\n\nAlways answer in Russian.")
        );
    }

    /// Content parts (vision) are not string content, so the prompt becomes a
    /// separate leading message and the parts survive untouched.
    #[test]
    fn prompt_keeps_content_parts() {
        let body = chat(json!([
            { "role": "system", "content": [{ "type": "text", "text": "rules" }] }
        ]));
        let merged = merge("You are terse.", "/v1/chat/completions", &body).unwrap();
        let result = messages(&merged);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0]["content"], json!("You are terse."));
        assert!(result[1]["content"].is_array());
    }

    /// The Responses API carries the system prompt in `instructions`.
    #[test]
    fn prompt_fills_responses_instructions() {
        let body = serde_json::to_vec(&json!({
            "model": "local/test",
            "instructions": "Be brief.",
            "input": "hi",
        }))
        .unwrap();
        let merged = merge("You are terse.", "/v1/responses", &body).unwrap();
        let value: Value = serde_json::from_slice(&merged).unwrap();
        assert_eq!(value["instructions"], json!("You are terse.\n\nBe brief."));

        let without = serde_json::to_vec(&json!({ "model": "local/test", "input": "hi" })).unwrap();
        let filled = merge("You are terse.", "/v1/responses", &without).unwrap();
        let filled_value: Value = serde_json::from_slice(&filled).unwrap();
        assert_eq!(filled_value["instructions"], json!("You are terse."));
    }

    /// Nothing to inject means the relay must forward the original bytes.
    #[test]
    fn merge_skips_empty_prompts_and_foreign_bodies() {
        let body = chat(json!([{ "role": "user", "content": "hi" }]));
        assert!(merge("   ", "/v1/chat/completions", &body).is_none());
        assert!(merge("x", "/v1/models", &body).is_none());
        assert!(merge("x", "/v1/chat/completions", br#"{"model":"local/test"}"#).is_none());
    }

    #[test]
    fn rewrite_targets_only_chat_and_responses() {
        assert!(is_rewritable("/v1/chat/completions?x=1"));
        assert!(is_rewritable("/v1/responses"));
        assert!(!is_rewritable("/v1/models"));
        assert!(!is_rewritable("/v1/completions"));
    }

    #[test]
    fn local_alias_resolves_to_the_same_model() {
        assert_eq!(canonical_model_id("local/qwen-test"), "qwen-test");
        assert_eq!(canonical_model_id("qwen-test"), "qwen-test");
    }

    #[test]
    fn model_id_reads_the_request_body() {
        assert_eq!(
            model_id(br#"{"model":"qwen-test"}"#).as_deref(),
            Some("qwen-test")
        );
        assert!(model_id(b"{}").is_none());
        assert!(model_id(b"not json").is_none());
    }

    // MARK: - Socket-level relay

    /// One-shot HTTP server standing in for the llama.cpp router. Returns its
    /// port and a channel carrying the request body it received.
    fn fake_router(chunked: bool) -> (u16, std::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let mut buffer = Vec::new();
            let mut chunk = [0u8; 8192];
            let mut expected: Option<usize> = None;
            let mut body_start = 0usize;
            loop {
                if expected.is_none() {
                    if let Some(index) = find(&buffer, b"\r\n\r\n") {
                        body_start = index + 4;
                        expected = Some(content_length(&buffer[..index]));
                    }
                }
                if let Some(length) = expected {
                    if buffer.len() >= body_start + length {
                        break;
                    }
                }
                let read = stream.read(&mut chunk).unwrap_or(0);
                if read == 0 {
                    break;
                }
                buffer.extend_from_slice(&chunk[..read]);
            }
            let body = match expected {
                Some(length) => {
                    String::from_utf8_lossy(&buffer[body_start..body_start + length]).to_string()
                }
                None => String::new(),
            };
            let payload =
                r#"{"id":"x","choices":[{"message":{"role":"assistant","content":"ok"}}]}"#;
            let response = if chunked {
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{}\r\n0\r\n\r\n",
                    payload.len(),
                    payload
                )
            } else {
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                    payload.len(),
                    payload
                )
            };
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
            let _ = sender.send(body);
        });
        (port, receiver)
    }

    fn content_length(head: &[u8]) -> usize {
        String::from_utf8_lossy(head)
            .split("\r\n")
            .filter_map(|line| line.split_once(':'))
            .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, value)| value.trim().parse().ok())
            .unwrap_or(0)
    }

    /// Sends one request to a relay instance wired to `upstream` and returns
    /// the raw answer.
    fn round_trip(
        upstream: u16,
        prompt: Option<&str>,
        method: &str,
        target: &str,
        body: &str,
    ) -> String {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let relay_port = listener.local_addr().unwrap().port();
        let prompt = prompt.map(str::to_string);
        std::thread::spawn(move || {
            if let Ok((server, _)) = listener.accept() {
                handle_with(server, upstream, move |_| prompt.clone());
            }
        });

        let mut client = TcpStream::connect(("127.0.0.1", relay_port)).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let request = format!(
            "{method} {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n{body}",
            body.len()
        );
        client.write_all(request.as_bytes()).unwrap();
        let mut response = String::new();
        let _ = client.read_to_string(&mut response);
        response
    }

    #[test]
    fn relay_injects_the_prompt_and_returns_the_answer() {
        let (router_port, captured) = fake_router(false);
        let body = r#"{"model":"qwen-test","messages":[{"role":"user","content":"hi"}]}"#;
        let response = round_trip(
            router_port,
            Some("You are terse."),
            "POST",
            "/v1/chat/completions",
            body,
        );

        assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
        assert!(response.contains(r#""content":"ok""#), "{response}");
        assert!(
            response.to_ascii_lowercase().contains("connection: close"),
            "{response}"
        );

        let forwarded = captured.recv_timeout(Duration::from_secs(10)).unwrap();
        let value: Value = serde_json::from_str(&forwarded).unwrap();
        let messages = value["messages"].as_array().unwrap();
        assert_eq!(messages[0]["role"], json!("system"));
        assert_eq!(messages[0]["content"], json!("You are terse."));
    }

    #[test]
    fn relay_keeps_chunked_responses_readable() {
        let (router_port, captured) = fake_router(true);
        let response = round_trip(router_port, None, "GET", "/v1/models", "");

        assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
        assert!(response.contains(r#""content":"ok""#), "{response}");
        assert!(response.contains("\r\n0\r\n\r\n"), "{response}");
        let _ = captured.recv_timeout(Duration::from_secs(10));
    }

    #[test]
    fn relay_reports_a_stopped_engine() {
        let response = round_trip(0, None, "GET", "/v1/models", "");
        assert!(response.starts_with("HTTP/1.1 503"), "{response}");
    }
}
