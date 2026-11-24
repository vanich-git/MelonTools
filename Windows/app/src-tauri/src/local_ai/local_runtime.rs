//! Lifecycle management and supervision of the `llama-server` process.

use super::hardware::InferenceBackend;
use super::local_models::{LocalModel, LocalModelSettings, LocalModelStore, ModelRuntimeStatus};
use crate::paths::{llama_server_exe_path, local_logs_dir, local_metadata_dir, local_runtime_dir};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::sync::watch;
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum LocalRuntimeState {
    Stopped,
    Starting { model_id: String },
    Running { port: u16, model_id: String },
    Failed { error: String },
}

/// Per-model state reported by the router's `GET /models` endpoint. Only
/// `loaded` means the weights are resident and the model can be advertised.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RouterModelState {
    Unloaded,
    Loading,
    Loaded,
    Sleeping,
    Failed,
    Unknown,
}

impl RouterModelState {
    fn from_wire(value: &str) -> Self {
        match value {
            "unloaded" => Self::Unloaded,
            "loading" => Self::Loading,
            "loaded" => Self::Loaded,
            "sleeping" => Self::Sleeping,
            "failed" => Self::Failed,
            _ => Self::Unknown,
        }
    }
}

/// Pinned llama.cpp b12099 router shape:
/// `{"data":[{"id":"...","status":{"value":"loaded"}}]}`.
fn parse_router_models(body: &str) -> Option<HashMap<String, RouterModelState>> {
    let value: Value = serde_json::from_str(body).ok()?;
    let entries = value.get("data")?.as_array()?;
    let mut states = HashMap::with_capacity(entries.len());
    for entry in entries {
        let Some(id) = entry.get("id").and_then(Value::as_str) else {
            continue;
        };
        let raw = entry
            .get("status")
            .and_then(|status| status.get("value"))
            .and_then(Value::as_str)
            .unwrap_or("unloaded");
        states.insert(id.to_string(), RouterModelState::from_wire(raw));
    }
    Some(states)
}

/// Maps one router state onto the registry status the gateway filter reads.
/// A model the live router does not list is not warm, so a stale `Ready`
/// (idle unload, router restart) falls back to `Installed`.
fn reconciled_registry_status(
    router: Option<RouterModelState>,
    current: ModelRuntimeStatus,
) -> ModelRuntimeStatus {
    match router {
        Some(RouterModelState::Loaded) => ModelRuntimeStatus::Ready,
        Some(RouterModelState::Loading) => ModelRuntimeStatus::Loading,
        Some(RouterModelState::Failed) => ModelRuntimeStatus::Error,
        Some(RouterModelState::Unloaded)
        | Some(RouterModelState::Sleeping)
        | Some(RouterModelState::Unknown) => ModelRuntimeStatus::Installed,
        None => match current {
            ModelRuntimeStatus::Ready | ModelRuntimeStatus::Loading => {
                ModelRuntimeStatus::Installed
            }
            other => other,
        },
    }
}

/// Extracts the router's error message and always keeps the HTTP status.
///
/// The status used to be dropped whenever the body carried text, so a rejected
/// key (401) and an out-of-memory kill (500) reached the Console as the same
/// bare phrase and a 401 could be mistaken for a slow load.
fn router_error_message(body: &str, status: u16) -> String {
    // A JSON body without a usable message yields no text at all: echoing the
    // raw JSON back would hide the status behind a wall of braces.
    let text = match serde_json::from_str::<Value>(body) {
        Ok(value) => value
            .get("error")
            .and_then(|error| error.get("message"))
            .or_else(|| value.get("message"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|message| !message.is_empty())
            .map(str::to_string)
            .unwrap_or_default(),
        Err(_) => body.trim().to_string(),
    };
    let text: String = text.chars().take(512).collect();
    if text.is_empty() {
        format!("HTTP {status}")
    } else {
        format!("HTTP {status}: {text}")
    }
}

/// The model the runtime currently serves, as the UI needs it. `id` is the
/// registry id the renderer keys the active card off (`currentModel.id`);
/// `modelId` stays on the payload as a compatibility alias.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeModelRef {
    pub id: String,
    pub display_name: String,
    pub quantization: String,
    pub file_size: u64,
    pub context_length: usize,
}

impl RuntimeModelRef {
    fn from_model(model: &LocalModel) -> Self {
        Self {
            id: model.id.clone(),
            display_name: model.display_name.clone(),
            quantization: model.quantization.clone(),
            file_size: model.file_size,
            context_length: model.context_length,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeStatusPayload {
    pub state: LocalRuntimeState,
    pub port: u16,
    /// The served model, `None` when nothing is running. `currentModel.id` is
    /// the field the renderer reads.
    pub current_model: Option<RuntimeModelRef>,
    /// Compatibility alias of `currentModel.id`, kept for older callers.
    pub model_id: Option<String>,
    pub internal_token: String,
    pub is_running: bool,
    /// True while the engine maps weights and has not answered /health yet, so
    /// the UI can show progress instead of a dead Start button.
    pub is_starting: bool,
    /// Model the in-flight launch belongs to.
    pub starting_model_id: Option<String>,
    /// Model whose launch failed; keeps the error on the right card.
    pub failed_model_id: Option<String>,
    pub error: Option<String>,
    pub binary_path: Option<String>,
    /// Incremented on every lifecycle transition. The command layer rewrites
    /// the gateway config when the value it last published differs, so a
    /// crash or a stop cannot leave a stale catalogue behind.
    pub revision: u64,
    /// Settings snapshot the running engine was launched with. A newer saved
    /// registry value is pending until the model is restarted.
    pub applied_settings: Option<LocalModelSettings>,
    /// Why the gateway catalogue does not match this runtime state. `None` once
    /// the live `/v1/models` list confirms the expected local aliases.
    pub publication_error: Option<String>,
}

/// Live counters and gauges from `llama-server --metrics`.
///
/// The router exposes a child's metrics only through `/metrics?model=<id>`
/// (without the query it answers 400), so the scrape always names the model.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeMetrics {
    pub model_id: Option<String>,
    pub prompt_tokens_total: Option<u64>,
    pub generated_tokens_total: Option<u64>,
    pub prompt_tokens_per_second: Option<f64>,
    pub generated_tokens_per_second: Option<f64>,
    pub requests_processing: Option<u64>,
    pub requests_deferred: Option<u64>,
}

const MAX_METRICS_BODY: usize = 512 * 1024;
/// Above this a "tokens/s" figure is a broken exposition (a counter divided
/// by a near-zero elapsed time), not a real rate.
const MAX_PLAUSIBLE_RATE: f64 = 100_000.0;

/// Builds the router scrape URL. The alias written into `models.ini` is the
/// model id, which is what the router resolves here.
pub fn metrics_url(port: u16, model_id: &str) -> String {
    let mut url = url::Url::parse(&format!("http://127.0.0.1:{}/metrics", port))
        .expect("loopback metrics URL is valid");
    url.query_pairs_mut().append_pair("model", model_id);
    url.to_string()
}

/// Parses the Prometheus exposition from `llama-server --metrics`.
/// Missing or unparsable values stay `None`; no estimate is invented.
pub fn parse_metrics(body: &str) -> RuntimeMetrics {
    parse_metrics_for(body, None)
}

/// Same parser with an optional model filter for labelled output. The
/// llama.cpp router proxies an unlabelled child exposition, but the label
/// path keeps a future multi-model scrape correct instead of mixing counters.
pub fn parse_metrics_for(body: &str, model_id: Option<&str>) -> RuntimeMetrics {
    let mut metrics = RuntimeMetrics::default();
    let mut prompt_seconds_total: Option<f64> = None;
    let mut generated_seconds_total: Option<f64> = None;

    for line in body.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        let (Some(raw_name), Some(raw_value)) = (parts.next(), parts.next()) else {
            continue;
        };
        let (name, labels) = match raw_name.split_once('{') {
            Some((name, rest)) => (name, rest.split('}').next().unwrap_or("")),
            None => (raw_name, ""),
        };
        if let (Some(wanted), Some(found)) = (model_id, metric_model_label(labels)) {
            if found != wanted {
                continue;
            }
        }
        match name {
            "llamacpp:prompt_tokens_total" => {
                metrics.prompt_tokens_total = parse_counter(raw_value)
            }
            "llamacpp:tokens_predicted_total" => {
                metrics.generated_tokens_total = parse_counter(raw_value)
            }
            "llamacpp:prompt_tokens_seconds" => {
                metrics.prompt_tokens_per_second = parse_rate(raw_value)
            }
            "llamacpp:predicted_tokens_seconds" => {
                metrics.generated_tokens_per_second = parse_rate(raw_value)
            }
            "llamacpp:prompt_seconds_total" => prompt_seconds_total = parse_gauge(raw_value),
            "llamacpp:tokens_predicted_seconds_total" => {
                generated_seconds_total = parse_gauge(raw_value)
            }
            "llamacpp:requests_processing" => {
                metrics.requests_processing = parse_counter(raw_value)
            }
            "llamacpp:requests_deferred" => metrics.requests_deferred = parse_counter(raw_value),
            _ => {}
        }
    }

    // The engine writes the throughput gauges when a task finishes and reports
    // 0 for the whole generation, so a zero gauge is "no sample yet", not
    // "0 tok/s". Fall back to the averages over the counters, but only once
    // they cover a meaningful interval: 2 tokens divided by a near-zero
    // `*_seconds_total` right after a start used to show 1000000.0 tok/s.
    if metrics.prompt_tokens_per_second.is_none() {
        if let (Some(tokens), Some(seconds)) = (metrics.prompt_tokens_total, prompt_seconds_total) {
            if seconds >= 1.0 && tokens > 0 {
                let rate = tokens as f64 / seconds;
                if rate.is_finite() && rate <= MAX_PLAUSIBLE_RATE {
                    metrics.prompt_tokens_per_second = Some(rate);
                }
            }
        }
    }
    if metrics.generated_tokens_per_second.is_none() {
        if let (Some(tokens), Some(seconds)) =
            (metrics.generated_tokens_total, generated_seconds_total)
        {
            if seconds >= 1.0 && tokens > 0 {
                let rate = tokens as f64 / seconds;
                if rate.is_finite() && rate <= MAX_PLAUSIBLE_RATE {
                    metrics.generated_tokens_per_second = Some(rate);
                }
            }
        }
    }

    if let Some(model_id) = model_id {
        metrics.model_id = Some(model_id.to_string());
    }
    metrics
}

fn parse_counter(value: &str) -> Option<u64> {
    value.parse::<u64>().ok().or_else(|| {
        value
            .parse::<f64>()
            .ok()
            .filter(|v| v.is_finite() && *v >= 0.0)
            .map(|v| v as u64)
    })
}

fn parse_gauge(value: &str) -> Option<f64> {
    value
        .parse::<f64>()
        .ok()
        .filter(|v| v.is_finite() && *v >= 0.0)
}

/// A gauge the renderer can show as tokens/s; 0 means "no sample yet".
fn parse_rate(value: &str) -> Option<f64> {
    parse_gauge(value).filter(|rate| *rate > 0.0 && *rate <= MAX_PLAUSIBLE_RATE)
}

fn metric_model_label(labels: &str) -> Option<&str> {
    for part in labels.split(',') {
        let Some(rest) = part.trim().strip_prefix("model=") else {
            continue;
        };
        return rest.trim().strip_prefix('"')?.strip_suffix('"');
    }
    None
}

/// Replaces the exposition's throughput with the rate observed since the last
/// poll. The counters are live, while `*_tokens_seconds` stays 0 until a task
/// finishes. A positive delta is the live rate; a zero delta keeps the last
/// known rate; a negative delta (restarted engine) keeps the exposition.
fn apply_live_rates(current: &mut RuntimeMetrics, previous: &RuntimeMetrics, elapsed: f64) {
    if !elapsed.is_finite() || elapsed < 1.0 {
        // Too soon for a delta: keep what the card showed a moment ago.
        current.generated_tokens_per_second = previous.generated_tokens_per_second;
        current.prompt_tokens_per_second = previous.prompt_tokens_per_second;
        return;
    }
    if let (Some(now), Some(before)) = (
        current.generated_tokens_total,
        previous.generated_tokens_total,
    ) {
        if now > before {
            let rate = (now - before) as f64 / elapsed;
            if rate.is_finite() && rate <= MAX_PLAUSIBLE_RATE {
                current.generated_tokens_per_second = Some(rate);
            } else {
                current.generated_tokens_per_second = previous.generated_tokens_per_second;
            }
        } else if now == before {
            current.generated_tokens_per_second = previous.generated_tokens_per_second;
        }
    }
    if let (Some(now), Some(before)) = (current.prompt_tokens_total, previous.prompt_tokens_total) {
        if now > before {
            let rate = (now - before) as f64 / elapsed;
            if rate.is_finite() && rate <= MAX_PLAUSIBLE_RATE {
                current.prompt_tokens_per_second = Some(rate);
            } else {
                current.prompt_tokens_per_second = previous.prompt_tokens_per_second;
            }
        } else if now == before {
            current.prompt_tokens_per_second = previous.prompt_tokens_per_second;
        }
    }
}

/// Scrapes one model over loopback. `no_proxy` matters on a machine with a
/// corporate proxy: `HTTP_PROXY` must never receive the engine token or turn a
/// loopback read into a remote call. The timeout and body cap bound a hung or
/// misbehaving engine.
/// Shared loopback client for the router probes.
///
/// A fresh `reqwest::Client` per call allocated its own connection pool every
/// two seconds (metrics poll) and every five seconds (router reconcile) for the
/// whole session. The gateway already keeps one client for the same reason.
fn router_client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(1))
            .timeout(Duration::from_secs(3))
            .build()
            .unwrap_or_default()
    })
}

async fn fetch_runtime_metrics(
    port: u16,
    token: &str,
    model_id: &str,
) -> Result<RuntimeMetrics, String> {
    let client = router_client();

    let mut response = client
        .get(metrics_url(port, model_id))
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .map_err(|e| format!("Metrics request failed: {}", e))?;

    if !response.status().is_success() {
        return Err(format!(
            "Metrics endpoint returned HTTP {}",
            response.status().as_u16()
        ));
    }
    if response.content_length().unwrap_or(0) > MAX_METRICS_BODY as u64 {
        return Err("Metrics response is larger than 512 KiB".to_string());
    }

    let mut body: Vec<u8> = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| format!("Metrics body read failed: {}", e))?
    {
        if body.len() + chunk.len() > MAX_METRICS_BODY {
            return Err("Metrics response is larger than 512 KiB".to_string());
        }
        body.extend_from_slice(&chunk);
    }

    Ok(parse_metrics_for(
        &String::from_utf8_lossy(&body),
        Some(model_id),
    ))
}

// MARK: - Engine log

/// Lines returned when the renderer does not ask for a specific count.
pub const DEFAULT_LOG_LINES: usize = 500;
/// Hard cap: the Console never needs more history than this.
pub const MAX_LOG_LINES: usize = 2_000;
/// Only the newest slice of the file is read, so a multi-gigabyte log costs a
/// bounded amount of memory and time on every poll.
const MAX_LOG_BYTES: u64 = 256 * 1024;
/// A single tournament-style line can be huge; cap it so the DOM stays sane.
const MAX_LOG_LINE_CHARS: usize = 2_000;

/// Reads the tail of the engine log, newest `max_lines` lines in chronological
/// order. A missing file is an empty log, not an error.
pub fn read_log_tail(path: &Path, max_lines: usize) -> Result<Vec<String>, String> {
    read_log_tail_after(path, max_lines, 0)
}

/// Same as [`read_log_tail`], but skips everything before the byte `after`.
/// The Console "Clear" records the current file size here instead of truncating
/// the file: the engine holds its own write handle, and cutting the file under
/// it leaves a NUL-filled gap until the next restart.
pub fn read_log_tail_after(
    path: &Path,
    max_lines: usize,
    after: u64,
) -> Result<Vec<String>, String> {
    let max_lines = max_lines.clamp(1, MAX_LOG_LINES);
    let mut file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("Failed to open the engine log: {}", error)),
    };
    let len = file
        .metadata()
        .map_err(|error| format!("Failed to read the engine log size: {}", error))?
        .len();
    // A restarted engine may have recreated a shorter file; then the stored
    // offset is meaningless and the whole tail is read.
    let floor = if after > len { 0 } else { after };
    let start = floor.max(len.saturating_sub(MAX_LOG_BYTES));
    if start >= len {
        return Ok(Vec::new());
    }
    file.seek(SeekFrom::Start(start))
        .map_err(|error| format!("Failed to seek the engine log: {}", error))?;
    let mut buffer = Vec::with_capacity((len - start) as usize);
    file.read_to_end(&mut buffer)
        .map_err(|error| format!("Failed to read the engine log: {}", error))?;

    let text = String::from_utf8_lossy(&buffer);
    let mut lines: Vec<&str> = text.lines().collect();
    // A byte-capped window can start in the middle of a line; a window that
    // starts exactly at the stored clear offset starts on a line boundary.
    if start > floor && !lines.is_empty() {
        lines.remove(0);
    }
    let tail_start = lines.len().saturating_sub(max_lines);
    Ok(lines[tail_start..]
        .iter()
        .map(|line| truncate_log_line(line))
        .collect())
}

fn truncate_log_line(line: &str) -> String {
    if line.chars().count() <= MAX_LOG_LINE_CHARS {
        return line.to_string();
    }
    let mut truncated: String = line.chars().take(MAX_LOG_LINE_CHARS).collect();
    truncated.push('…');
    truncated
}

/// Engine log cap on disk. The Console tail cap only bounds reads; without
/// this an always-on router fills the disk.
pub const ENGINE_LOG_MAX_BYTES: u64 = 8 * 1024 * 1024;
/// Rotated files kept beside the live log (`.1` is newest).
pub const ENGINE_LOG_BACKUPS: usize = 3;

fn rotated_log_path(path: &Path, index: usize) -> PathBuf {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "engine.log".to_string());
    path.with_file_name(format!("{name}.{index}"))
}

/// Rotates `path` once it reaches `max_bytes`: the oldest backup is dropped,
/// each one is shifted and the live file becomes `.1`. Returns whether it
/// rotated. A missing log is not an error.
pub fn rotate_log_file(path: &Path, max_bytes: u64, keep: usize) -> Result<bool, String> {
    let len = match fs::metadata(path) {
        Ok(meta) => meta.len(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(format!("Failed to inspect the engine log: {}", error)),
    };
    if max_bytes == 0 || keep == 0 || len < max_bytes {
        return Ok(false);
    }
    rotate_log_file_now(path, keep)?;
    Ok(true)
}

/// Shifts the backups unconditionally. The caller decides why it rotates (size
/// cap at launch, or a chunk that would cross the cap while the engine runs).
fn rotate_log_file_now(path: &Path, keep: usize) -> Result<(), String> {
    for index in (1..=keep).rev() {
        let target = rotated_log_path(path, index);
        if index == keep {
            let _ = fs::remove_file(&target);
        }
        let source = if index == 1 {
            path.to_path_buf()
        } else {
            rotated_log_path(path, index - 1)
        };
        if source.exists() {
            fs::rename(&source, &target)
                .map_err(|error| format!("Failed to rotate the engine log: {}", error))?;
        }
    }
    Ok(())
}

/// Bounds the engine log before the next launch appends to it.
pub fn prepare_engine_log(path: &Path) -> Result<(), String> {
    rotate_log_file(path, ENGINE_LOG_MAX_BYTES, ENGINE_LOG_BACKUPS).map(|_| ())
}

fn open_engine_log(path: &Path) -> Result<fs::File, String> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("Failed to open the engine log: {}", error))
}

/// Bounded writer for the engine's stdout/stderr.
///
/// The engine used to inherit a raw append handle, so nothing could rotate the
/// file while it ran: a router left on for weeks grew the log without limit.
/// Reading the pipes lets the app enforce `ENGINE_LOG_MAX_BYTES` at every
/// chunk, in-process, without restarting the engine.
struct EngineLogSink {
    path: PathBuf,
    file: Option<fs::File>,
    written: u64,
    max_bytes: u64,
    keep: usize,
}

impl EngineLogSink {
    fn open(path: &Path, max_bytes: u64, keep: usize) -> Result<Self, String> {
        prepare_engine_log(path)?;
        let file = open_engine_log(path)?;
        let written = file.metadata().map(|meta| meta.len()).unwrap_or(0);
        Ok(Self {
            path: path.to_path_buf(),
            file: Some(file),
            written,
            max_bytes,
            keep,
        })
    }

    fn write_chunk(&mut self, bytes: &[u8]) -> Result<(), String> {
        if self.max_bytes > 0
            && self.written > 0
            && self.written.saturating_add(bytes.len() as u64) > self.max_bytes
        {
            // Close before rename: Windows refuses to move an open file.
            self.file = None;
            rotate_log_file_now(&self.path, self.keep)?;
            self.file = Some(open_engine_log(&self.path)?);
            self.written = 0;
        }
        if let Some(file) = self.file.as_mut() {
            file.write_all(bytes)
                .map_err(|error| format!("Failed to write the engine log: {}", error))?;
            self.written = self.written.saturating_add(bytes.len() as u64);
        }
        Ok(())
    }
}

/// Drains one engine pipe into the bounded log. A disk error must not stop the
/// reader: the engine would block on a full pipe, so output is dropped instead.
fn pump_engine_log<R: Read + Send + 'static>(reader: R, sink: Arc<Mutex<EngineLogSink>>) {
    std::thread::spawn(move || {
        let mut reader = reader;
        let mut buffer = [0u8; 8 * 1024];
        let mut writable = true;
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    if writable {
                        match sink.lock() {
                            Ok(mut sink) => {
                                if sink.write_chunk(&buffer[..read]).is_err() {
                                    writable = false;
                                }
                            }
                            Err(_) => writable = false,
                        }
                    }
                }
                Err(_) => break,
            }
        }
    });
}

// MARK: - Runtime package install

/// Stages reported to the UI. The Mac build uses the same names for its
/// tar.gz package so one renderer can drive both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeInstallStage {
    Idle,
    Downloading,
    Verifying,
    Extracting,
    Validating,
    Publishing,
    Done,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeInstallStatus {
    pub stage: RuntimeInstallStage,
    pub bytes_downloaded: u64,
    pub total_bytes: u64,
    pub progress: f64,
    pub speed_bytes_per_sec: u64,
    pub error: Option<String>,
    pub package_id: Option<String>,
    /// Absolute path of the validated `llama-server.exe`. The UI selects it as
    /// the custom binary only after the engine is stopped.
    pub binary_path: Option<String>,
}

impl Default for RuntimeInstallStatus {
    fn default() -> Self {
        Self {
            stage: RuntimeInstallStage::Idle,
            bytes_downloaded: 0,
            total_bytes: 0,
            progress: 0.0,
            speed_bytes_per_sec: 0,
            error: None,
            package_id: None,
            binary_path: None,
        }
    }
}

const MAX_RUNTIME_ARCHIVE_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAX_ZIP_ENTRIES: usize = 1024;
const MAX_ZIP_ENTRY_BYTES: u64 = 2 * 1024 * 1024 * 1024;
const MAX_ZIP_TOTAL_BYTES: u64 = 4 * 1024 * 1024 * 1024;

/// Owns the single install slot. One download at a time keeps progress and
/// cancellation unambiguous; two concurrent packages would fight for the
/// runtime directory.
pub struct RuntimeInstaller {
    status: Arc<Mutex<RuntimeInstallStatus>>,
    active: Arc<Mutex<bool>>,
    cancel: Arc<Mutex<Option<watch::Sender<bool>>>>,
}

impl Clone for RuntimeInstaller {
    fn clone(&self) -> Self {
        Self {
            status: Arc::clone(&self.status),
            active: Arc::clone(&self.active),
            cancel: Arc::clone(&self.cancel),
        }
    }
}

impl Default for RuntimeInstaller {
    fn default() -> Self {
        Self::new()
    }
}

impl RuntimeInstaller {
    pub fn new() -> Self {
        Self {
            status: Arc::new(Mutex::new(RuntimeInstallStatus::default())),
            active: Arc::new(Mutex::new(false)),
            cancel: Arc::new(Mutex::new(None)),
        }
    }

    pub fn status(&self) -> RuntimeInstallStatus {
        self.status
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Validates the request synchronously so the UI gets an immediate error,
    /// then streams the archive in the background.
    pub fn start(&self, url: &str, sha256: &str) -> Result<String, String> {
        let url = validate_install_url(url)?;
        let digest = normalize_sha256(sha256)?;
        let package_id = package_id_for(&digest);

        {
            let mut active = self.active.lock().unwrap_or_else(|e| e.into_inner());
            if *active {
                return Err("A runtime install is already running.".to_string());
            }
            let final_dir = local_runtime_dir().join("packages").join(&package_id);
            if final_dir.exists() {
                return Err(format!(
                    "Runtime package {} is already installed; remove that folder before retrying.",
                    package_id
                ));
            }
            *active = true;
        }

        {
            let mut status = self.status.lock().unwrap_or_else(|e| e.into_inner());
            *status = RuntimeInstallStatus {
                stage: RuntimeInstallStage::Downloading,
                package_id: Some(package_id.clone()),
                ..RuntimeInstallStatus::default()
            };
        }

        let (cancel_tx, cancel_rx) = watch::channel(false);
        *self.cancel.lock().unwrap_or_else(|e| e.into_inner()) = Some(cancel_tx);

        let installer = self.clone();
        let package = package_id.clone();
        // A sync IPC command may run outside the tokio reactor; Tauri's
        // runtime handle is safe from any thread and never panics on spawn.
        tauri::async_runtime::spawn(async move {
            let outcome = installer.run(url, digest, package, cancel_rx).await;
            installer.finish(outcome);
        });

        Ok(package_id)
    }

    pub fn cancel(&self) {
        if let Some(sender) = self.cancel.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = sender.send(true);
        }
    }

    fn update<F: FnOnce(&mut RuntimeInstallStatus)>(&self, update: F) {
        let mut status = self.status.lock().unwrap_or_else(|e| e.into_inner());
        update(&mut status);
    }

    fn set_stage(&self, stage: RuntimeInstallStage) {
        self.update(|status| status.stage = stage);
    }

    fn finish(&self, outcome: InstallOutcome) {
        self.update(|status| match outcome {
            InstallOutcome::Done {
                package_id,
                binary_path,
                bytes,
            } => {
                status.stage = RuntimeInstallStage::Done;
                status.package_id = Some(package_id);
                status.binary_path = Some(binary_path);
                status.progress = 1.0;
                status.bytes_downloaded = bytes;
                status.speed_bytes_per_sec = 0;
                status.error = None;
            }
            InstallOutcome::Cancelled => {
                status.stage = RuntimeInstallStage::Cancelled;
                status.speed_bytes_per_sec = 0;
                status.error = None;
            }
            InstallOutcome::Failed(error) => {
                status.stage = RuntimeInstallStage::Failed;
                status.speed_bytes_per_sec = 0;
                status.error = Some(error);
            }
        });
        *self.active.lock().unwrap_or_else(|e| e.into_inner()) = false;
        *self.cancel.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    async fn run(
        &self,
        url: url::Url,
        digest: String,
        package_id: String,
        mut cancel: watch::Receiver<bool>,
    ) -> InstallOutcome {
        match self.run_inner(url, digest, package_id, &mut cancel).await {
            Ok(outcome) => outcome,
            Err(error) => InstallOutcome::Failed(error),
        }
    }

    async fn run_inner(
        &self,
        url: url::Url,
        digest: String,
        package_id: String,
        cancel: &mut watch::Receiver<bool>,
    ) -> Result<InstallOutcome, String> {
        let runtime_root = local_runtime_dir();
        fs::create_dir_all(&runtime_root)
            .map_err(|e| format!("Cannot create runtime directory: {}", e))?;

        let archive_path = runtime_root.join(format!(".install-{}.zip", package_id));
        let staging_dir = runtime_root.join(format!(".install-{}", package_id));
        let final_dir = runtime_root.join("packages").join(&package_id);

        // Only our deterministic staging names are removed. An installed
        // package and the active runtime are never touched by an install.
        let _ = fs::remove_file(&archive_path);
        let _ = fs::remove_dir_all(&staging_dir);
        let _guard = StagingGuard {
            archive: archive_path.clone(),
            staging: staging_dir.clone(),
        };

        self.set_stage(RuntimeInstallStage::Downloading);
        // The package comes from GitHub, so it follows the same explicit
        // proxy setting as every other external download.
        let client = crate::proxy::apply(reqwest::Client::builder())
            .connect_timeout(Duration::from_secs(20))
            .timeout(Duration::from_secs(30 * 60))
            .build()
            .map_err(|e| format!("Cannot build download client: {}", e))?;

        let response = tokio::select! {
            biased;
            _ = cancel_signal(cancel) => return Ok(InstallOutcome::Cancelled),
            response = client.get(url).send() => {
                response.map_err(|e| format!("Runtime download failed: {}", e))?
            }
        };

        if !response.status().is_success() {
            return Err(format!(
                "Runtime download returned HTTP {}",
                response.status().as_u16()
            ));
        }
        let total_bytes = response.content_length().unwrap_or(0);
        if total_bytes > MAX_RUNTIME_ARCHIVE_BYTES {
            return Err(format!(
                "Runtime archive is larger than the {} GiB limit",
                MAX_RUNTIME_ARCHIVE_BYTES / 1024 / 1024 / 1024
            ));
        }
        self.update(|status| status.total_bytes = total_bytes);

        let mut file = tokio::fs::File::create(&archive_path)
            .await
            .map_err(|e| format!("Cannot create staging archive: {}", e))?;
        let mut stream = response.bytes_stream();
        let mut hasher = Sha256::new();
        let mut downloaded: u64 = 0;
        let mut last_report = Instant::now();
        let mut last_bytes: u64 = 0;

        loop {
            let next = tokio::select! {
                biased;
                _ = cancel_signal(cancel) => return Ok(InstallOutcome::Cancelled),
                next = stream.next() => next,
            };
            let Some(chunk) = next else { break };
            let chunk = chunk.map_err(|e| format!("Runtime download stream failed: {}", e))?;
            downloaded = downloaded.saturating_add(chunk.len() as u64);
            if downloaded > MAX_RUNTIME_ARCHIVE_BYTES {
                return Err("Runtime archive exceeded the size limit".to_string());
            }
            hasher.update(&chunk);
            file.write_all(&chunk)
                .await
                .map_err(|e| format!("Cannot write staging archive: {}", e))?;

            let elapsed = last_report.elapsed().as_secs_f64();
            if elapsed >= 0.5 {
                let speed = ((downloaded - last_bytes) as f64 / elapsed) as u64;
                self.update(|status| {
                    status.bytes_downloaded = downloaded;
                    status.speed_bytes_per_sec = speed;
                    status.progress = if total_bytes > 0 {
                        downloaded as f64 / total_bytes as f64
                    } else {
                        0.0
                    };
                });
                last_report = Instant::now();
                last_bytes = downloaded;
            }
        }
        file.flush()
            .await
            .map_err(|e| format!("Cannot flush staging archive: {}", e))?;
        drop(file);

        if total_bytes > 0 && downloaded != total_bytes {
            return Err(format!(
                "Incomplete runtime download: {} of {} bytes",
                downloaded, total_bytes
            ));
        }

        self.set_stage(RuntimeInstallStage::Verifying);
        self.update(|status| {
            status.bytes_downloaded = downloaded;
            status.progress = 1.0;
        });
        let actual = format!("{:x}", hasher.finalize());
        if actual != digest {
            return Err(
                "SHA-256 mismatch: the runtime archive is corrupted or was replaced upstream."
                    .to_string(),
            );
        }

        if *cancel.borrow() {
            return Ok(InstallOutcome::Cancelled);
        }

        self.set_stage(RuntimeInstallStage::Extracting);
        let archive_for_extract = archive_path.clone();
        let staging_for_extract = staging_dir.clone();
        let extracted = tokio::task::spawn_blocking(move || {
            extract_runtime_zip(&archive_for_extract, &staging_for_extract)
        })
        .await
        .map_err(|e| format!("Runtime extraction task failed: {}", e))?;
        extracted?;

        if *cancel.borrow() {
            return Ok(InstallOutcome::Cancelled);
        }

        self.set_stage(RuntimeInstallStage::Validating);
        let binary_relative = find_llama_server(&staging_dir)
            .ok_or_else(|| "Archive does not contain llama-server.exe".to_string())?;
        validate_pe_x64(&staging_dir.join(&binary_relative))?;
        let binary_relative = binary_relative
            .strip_prefix(&staging_dir)
            .map_err(|_| "Invalid extracted executable path".to_string())?
            .to_path_buf();

        self.set_stage(RuntimeInstallStage::Publishing);
        let packages_dir = runtime_root.join("packages");
        fs::create_dir_all(&packages_dir)
            .map_err(|e| format!("Cannot create packages directory: {}", e))?;
        if final_dir.exists() {
            return Err(format!(
                "Runtime package {} was installed by another process",
                package_id
            ));
        }
        fs::rename(&staging_dir, &final_dir)
            .map_err(|e| format!("Cannot publish runtime package: {}", e))?;

        let binary_path = final_dir.join(binary_relative);
        if !binary_path.is_file() {
            // Only the package published by this call is removed; the active
            // runtime and other packages are never touched.
            let _ = fs::remove_dir_all(&final_dir);
            return Err("Published runtime is missing llama-server.exe".to_string());
        }

        Ok(InstallOutcome::Done {
            package_id,
            binary_path: binary_path.to_string_lossy().to_string(),
            bytes: downloaded,
        })
    }
}

enum InstallOutcome {
    Done {
        package_id: String,
        binary_path: String,
        bytes: u64,
    },
    Cancelled,
    Failed(String),
}

/// Deletes only this install's staging archive and directory on every exit
/// path. The published package and the active runtime live elsewhere.
struct StagingGuard {
    archive: PathBuf,
    staging: PathBuf,
}

impl Drop for StagingGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.archive);
        let _ = fs::remove_dir_all(&self.staging);
    }
}

async fn cancel_signal(cancel: &mut watch::Receiver<bool>) {
    if *cancel.borrow() {
        return;
    }
    let _ = cancel.changed().await;
}

pub fn validate_install_url(raw: &str) -> Result<url::Url, String> {
    let url =
        url::Url::parse(raw.trim()).map_err(|e| format!("Invalid runtime archive URL: {}", e))?;
    // The archive is executed after extraction, so it must not travel over
    // plaintext HTTP where anyone on the path can swap the bytes.
    if url.scheme() != "https" {
        return Err(
            "Runtime archive URL must use https; plain http is not accepted because the archive is executed."
                .to_string(),
        );
    }
    if url.host_str().unwrap_or("").is_empty() {
        return Err("Runtime archive URL has no host".to_string());
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("Runtime archive URL must not contain credentials".to_string());
    }
    Ok(url)
}

pub fn normalize_sha256(raw: &str) -> Result<String, String> {
    let digest = raw.trim().to_ascii_lowercase();
    if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("A 64-character SHA-256 of the archive is required".to_string());
    }
    Ok(digest)
}

fn package_id_for(digest: &str) -> String {
    digest[..12].to_string()
}

/// Rejects absolute paths and `..` even though `enclosed_name` already
/// normalizes them: the explicit check is cheap and documents the invariant.
fn safe_entry_path(path: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::Normal(part) => out.push(part),
            std::path::Component::CurDir => {}
            _ => return None,
        }
    }
    (!out.as_os_str().is_empty()).then_some(out)
}

/// Windows-specific names that create an alternate data stream, escape the
/// extraction directory or hit a reserved device. Archive entry names are
/// attacker-controlled even when the digest came from a trusted page.
fn is_safe_component(name: &std::ffi::OsStr) -> bool {
    let name = name.to_string_lossy();
    if name.is_empty() || name.len() > 255 || name.contains(':') {
        return false;
    }
    if name.ends_with('.') || name.ends_with(' ') {
        return false;
    }
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL") {
        return false;
    }
    let reserved_number = stem
        .strip_prefix("COM")
        .or_else(|| stem.strip_prefix("LPT"))
        .and_then(|rest| rest.parse::<u8>().ok())
        .map(|number| (1..=9).contains(&number))
        .unwrap_or(false);
    !reserved_number
}

fn extract_runtime_zip(archive_path: &Path, staging: &Path) -> Result<(), String> {
    use std::io::{Read, Write};

    let file =
        fs::File::open(archive_path).map_err(|e| format!("Cannot open runtime archive: {}", e))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|e| format!("Cannot read runtime archive: {}", e))?;
    if archive.len() > MAX_ZIP_ENTRIES {
        return Err(format!(
            "Runtime archive has more than {} entries",
            MAX_ZIP_ENTRIES
        ));
    }
    fs::create_dir_all(staging)
        .map_err(|e| format!("Cannot create extraction directory: {}", e))?;

    let mut declared_total: u64 = 0;
    let mut written_total: u64 = 0;
    for index in 0..archive.len() {
        let entry = archive
            .by_index(index)
            .map_err(|e| format!("Cannot read archive entry: {}", e))?;
        // zip 9 returns the decoded name as a Result; an undecodable name is
        // itself a reason to reject the entry, not just an error message.
        let entry_name = entry
            .name()
            .map(|name| name.into_owned())
            .unwrap_or_else(|_| "<invalid zip entry name>".to_string());
        let Some(enclosed) = entry.enclosed_name() else {
            return Err(format!("Unsafe archive path: {}", entry_name));
        };
        let Some(relative) = safe_entry_path(&enclosed) else {
            return Err(format!("Unsafe archive path: {}", entry_name));
        };
        for component in relative.components() {
            if let std::path::Component::Normal(name) = component {
                if !is_safe_component(name) {
                    return Err(format!("Unsafe archive entry name: {}", entry_name));
                }
            }
        }
        if entry.is_symlink() {
            return Err(format!("Symlink inside runtime archive: {}", entry_name));
        }
        if let Some(mode) = entry.unix_mode() {
            let kind = mode & 0o170000;
            if kind != 0 && kind != 0o100000 && kind != 0o040000 {
                return Err(format!(
                    "Special file inside runtime archive: {}",
                    entry_name
                ));
            }
        }

        let target = staging.join(&relative);
        if !target.starts_with(staging) {
            return Err(format!("Archive entry escapes staging: {}", entry_name));
        }
        if entry.is_dir() {
            fs::create_dir_all(&target)
                .map_err(|e| format!("Cannot create extracted directory: {}", e))?;
            continue;
        }

        let size = entry.size();
        if size > MAX_ZIP_ENTRY_BYTES {
            return Err(format!("Archive entry is too large: {}", entry_name));
        }
        declared_total = declared_total.saturating_add(size);
        if declared_total > MAX_ZIP_TOTAL_BYTES {
            return Err("Archive expands beyond the size limit".to_string());
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("Cannot create extraction directory: {}", e))?;
        }
        let mut output = fs::File::create(&target)
            .map_err(|e| format!("Cannot create extracted file: {}", e))?;
        let copied = {
            let mut limited = entry.take(MAX_ZIP_ENTRY_BYTES + 1);
            std::io::copy(&mut limited, &mut output)
                .map_err(|e| format!("Cannot extract archive entry: {}", e))?
        };
        if copied > MAX_ZIP_ENTRY_BYTES {
            return Err(format!("Archive entry is too large: {}", entry_name));
        }
        written_total = written_total.saturating_add(copied);
        // Declared sizes can lie; cap what actually reaches the disk too.
        if written_total > MAX_ZIP_TOTAL_BYTES {
            return Err("Archive expands beyond the size limit".to_string());
        }
        output
            .flush()
            .map_err(|e| format!("Cannot flush extracted file: {}", e))?;
    }
    Ok(())
}

fn find_llama_server(root: &Path) -> Option<PathBuf> {
    fn walk(directory: &Path, depth: usize) -> Option<PathBuf> {
        if depth > 3 {
            return None;
        }
        let mut directories = Vec::new();
        for entry in fs::read_dir(directory).ok()?.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_file()
                && entry
                    .file_name()
                    .to_string_lossy()
                    .eq_ignore_ascii_case("llama-server.exe")
            {
                return Some(entry.path());
            }
            if file_type.is_dir() {
                directories.push(entry.path());
            }
        }
        directories
            .into_iter()
            .find_map(|dir| walk(&dir, depth + 1))
    }
    walk(root, 0)
}

/// Reads the PE header without loading or executing the binary. Only the
/// machine type matters here: the archive digest already proved integrity,
/// and the engine is never started during install.
fn validate_pe_x64(path: &Path) -> Result<(), String> {
    use std::io::{Read, Seek, SeekFrom};

    let mut file =
        fs::File::open(path).map_err(|e| format!("Cannot open runtime executable: {}", e))?;
    let length = file
        .metadata()
        .map_err(|e| format!("Cannot stat runtime executable: {}", e))?
        .len();
    if length < 0x40 + 24 {
        return Err("Runtime executable is too small to be a PE file".to_string());
    }

    let mut dos = [0u8; 0x40];
    file.read_exact(&mut dos)
        .map_err(|e| format!("Cannot read runtime executable header: {}", e))?;
    if &dos[..2] != b"MZ" {
        return Err("Runtime executable is not a Windows PE file (missing MZ)".to_string());
    }
    let pe_offset = u32::from_le_bytes([dos[0x3c], dos[0x3d], dos[0x3e], dos[0x3f]]) as u64;
    if pe_offset > 1024 * 1024 || pe_offset.saturating_add(24) > length {
        return Err("Runtime executable has an invalid PE offset".to_string());
    }

    file.seek(SeekFrom::Start(pe_offset))
        .map_err(|e| format!("Cannot seek runtime executable header: {}", e))?;
    let mut header = [0u8; 24];
    file.read_exact(&mut header)
        .map_err(|e| format!("Cannot read PE header: {}", e))?;
    if &header[..4] != b"PE\0\0" {
        return Err("Runtime executable has no PE signature".to_string());
    }
    let machine = u16::from_le_bytes([header[4], header[5]]);
    if machine != 0x8664 {
        return Err(format!(
            "Runtime executable is not x64 (machine 0x{:04x})",
            machine
        ));
    }
    Ok(())
}

pub fn get_runtime_port() -> u16 {
    let port_path = local_metadata_dir().join("runtime_port.txt");
    if let Ok(content) = fs::read_to_string(&port_path) {
        if let Ok(port) = content.trim().parse::<u16>() {
            return port;
        }
    }
    18318
}

pub fn save_runtime_port(port: u16) {
    let port_path = local_metadata_dir().join("runtime_port.txt");
    let _ = fs::create_dir_all(local_metadata_dir());
    let _ = fs::write(&port_path, port.to_string());
}

pub fn get_or_create_internal_token() -> String {
    let token_path = local_metadata_dir().join("runtime_token.txt");
    if let Ok(content) = fs::read_to_string(&token_path) {
        let trimmed = content.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    let token = Uuid::new_v4().to_string();
    let _ = fs::create_dir_all(local_metadata_dir());
    let _ = fs::write(&token_path, &token);
    token
}

fn custom_binary_path_file() -> PathBuf {
    local_runtime_dir().join("binary_path.txt")
}

/// PID of the running engine process group. The Windows job object already
/// kills the tree when the app closes; macOS has no such safety net, so the
/// pid is recorded here and reaped on the next launch.
fn engine_pid_file() -> PathBuf {
    local_metadata_dir().join("engine.pid")
}

fn remember_engine_pid(pid: u32) {
    if pid == 0 {
        return;
    }
    let _ = fs::create_dir_all(local_metadata_dir());
    let _ = fs::write(engine_pid_file(), pid.to_string());
}

fn forget_engine_pid() {
    let _ = fs::remove_file(engine_pid_file());
}

/// How long a signalled engine may take to disappear before it is killed
/// again. A process wedged in GPU teardown must not hold the runtime forever.
const ENGINE_EXIT_TIMEOUT: Duration = Duration::from_secs(3);

/// Spawn attempts when the chosen port is taken before llama-server binds it.
/// `find_available_port` cannot reserve the port, so a lost race is retried on
/// the next candidate instead of failing the whole launch.
const ENGINE_PORT_ATTEMPTS: u8 = 3;

/// True when the engine log written since `from` names a bind failure. Only a
/// bounded tail is scanned, and only bytes from the current attempt count: an
/// older failure in the same file must not fail a healthy start.
fn log_reports_bind_failure(path: &Path, from: u64) -> bool {
    const TAIL: u64 = 64 << 10;
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    // A rotated/truncated file holds this attempt only, so start from zero.
    let start = if metadata.len() >= from { from } else { 0 };
    let end = metadata.len().min(start.saturating_add(TAIL));
    let Ok(mut file) = fs::File::open(path) else {
        return false;
    };
    if file.seek(SeekFrom::Start(start)).is_err() {
        return false;
    }
    let mut buffer = Vec::new();
    if file
        .take(end.saturating_sub(start))
        .read_to_end(&mut buffer)
        .is_err()
    {
        return false;
    }
    let tail = String::from_utf8_lossy(&buffer).to_ascii_lowercase();
    [
        "address already in use",
        "couldn't bind",
        "failed to bind",
        "bind error",
        "eaddrinuse",
    ]
    .iter()
    .any(|needle| tail.contains(needle))
}

/// Signals the router and every process it started to die, without waiting.
///
/// llama.cpp's router mode runs one `llama-server` child per loaded model.
/// `Child::kill` only terminates the router, so the child kept the weights in
/// RAM and the model port busy; on Unix nothing ever reaped it, not even after
/// a clean quit. Split from the wait so async callers can await the exit
/// instead of parking a runtime worker on `std::thread::sleep`.
fn signal_engine_termination(child: &mut Child) {
    let pid = child.id();
    #[cfg(windows)]
    {
        if pid != 0 {
            let mut command = Command::new("taskkill");
            command.args(["/PID", &pid.to_string(), "/T", "/F"]);
            use std::os::windows::process::CommandExt;
            const CREATE_NO_WINDOW: u32 = 0x08000000;
            command.creation_flags(CREATE_NO_WINDOW);
            let _ = command.output();
        }
    }
    #[cfg(unix)]
    {
        if pid != 0 {
            // The engine is spawned as its own process group leader, so the
            // negative pid reaches the router and each model child.
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
    }
    // Covers a failed taskkill/killpg and gives `try_wait` a reason to report
    // the exit promptly.
    let _ = child.kill();
}

/// Blocks until the signalled engine is reaped, killing it once more when it
/// outlives [`ENGINE_EXIT_TIMEOUT`]. Every lifecycle path is async and awaits
/// [`terminate_engine_async`]; this stays for synchronous callers.
#[allow(dead_code)]
fn terminate_engine(child: &mut Child) {
    signal_engine_termination(child);
    let deadline = Instant::now() + ENGINE_EXIT_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(20));
            }
            _ => {
                let _ = child.kill();
                return;
            }
        }
    }
}

/// Same contract as [`terminate_engine`] without blocking a runtime worker:
/// the wait yields to the executor instead of sleeping the thread.
async fn terminate_engine_async(child: &mut Child) {
    signal_engine_termination(child);
    let deadline = Instant::now() + ENGINE_EXIT_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            _ => {
                let _ = child.kill();
                return;
            }
        }
    }
}

/// Kills an engine left behind by a crash on a platform without a job object.
#[cfg(unix)]
#[cfg_attr(test, allow(dead_code))]
fn reap_orphan_engine() {
    let path = engine_pid_file();
    let Ok(text) = fs::read_to_string(&path) else {
        return;
    };
    let _ = fs::remove_file(&path);
    let Some(pid) = text.trim().parse::<u32>().ok().filter(|pid| *pid != 0) else {
        return;
    };
    // Process ids are reused after a reboot. Only signal the group when the
    // recorded pid still names our engine binary.
    let output = Command::new("ps")
        .args(["-o", "command=", "-p", &pid.to_string()])
        .output();
    let command = output
        .map(|out| String::from_utf8_lossy(&out.stdout).to_string())
        .unwrap_or_default();
    if !command.contains("llama-server") {
        return;
    }
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
}

#[cfg(windows)]
#[cfg_attr(test, allow(dead_code))]
fn reap_orphan_engine() {
    let path = engine_pid_file();
    let Ok(text) = fs::read_to_string(&path) else {
        return;
    };
    let _ = fs::remove_file(&path);
    let Some(pid) = text.trim().parse::<u32>().ok().filter(|pid| *pid != 0) else {
        return;
    };
    // The job object normally takes the tree down with the app, but a crash
    // before `assign` or a failed assignment leaves the engine running. Pids
    // are reused after a reboot, so only a pid that still names our binary is
    // killed; anything else is left alone.
    let Some(image) = windows_process_image(pid) else {
        return;
    };
    if !image.to_ascii_lowercase().contains("llama-server") {
        return;
    }
    let mut command = Command::new("taskkill");
    command.args(["/PID", &pid.to_string(), "/T", "/F"]);
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;
    command.creation_flags(CREATE_NO_WINDOW);
    let _ = command.output();
}

/// Image name of a live process, or `None` when the pid is gone or `tasklist`
/// could not answer. The command prints one CSV row per match; a localized
/// "no tasks" notice is not a row and has no leading quote.
#[cfg(windows)]
#[cfg_attr(test, allow(dead_code))]
fn windows_process_image(pid: u32) -> Option<String> {
    let mut command = Command::new("tasklist");
    command.args(["/FI", &format!("PID eq {pid}"), "/FO", "CSV", "/NH"]);
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;
    command.creation_flags(CREATE_NO_WINDOW);
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().next()?.trim();
    if !line.starts_with('"') {
        return None;
    }
    let name = line.trim_start_matches('"').split('"').next()?.trim();
    (!name.is_empty()).then(|| name.to_string())
}

fn load_custom_binary_path() -> Option<PathBuf> {
    let raw = fs::read_to_string(custom_binary_path_file()).ok()?;
    let path = PathBuf::from(raw.trim());
    path.is_file().then_some(path)
}

/// How long the first model start may wait for the engine download. The
/// archive is roughly 40–120 MB, so a slow link still finishes inside this.
const ENGINE_INSTALL_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const ENGINE_INSTALL_POLL: Duration = Duration::from_millis(250);

/// Binary of the newest installed runtime package. Packages are published as
/// `runtime/packages/<digest prefix>`, so the lexicographically last folder is
/// the most recent install.
fn installed_package_binary() -> Option<PathBuf> {
    let packages = local_runtime_dir().join("packages");
    let mut directories: Vec<PathBuf> = fs::read_dir(packages)
        .ok()?
        .flatten()
        .filter(|entry| entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false))
        .map(|entry| entry.path())
        .collect();
    directories.sort();
    directories
        .into_iter()
        .rev()
        .find_map(|package| find_llama_server(&package))
}

/// The variant the first-launch download should install. Vulkan is preferred
/// when the hardware detector found a Vulkan-capable GPU; the CPU build is the
/// safe fallback, exactly like the Runtime tab's default row.
fn preferred_runtime_variant() -> &'static str {
    let hardware = super::hardware::detect_hardware(None);
    if hardware.recommended_backend == InferenceBackend::Vulkan {
        "vulkan"
    } else {
        "cpu"
    }
}

/// Newest release that ships the requested variant, as `(url, sha256)`.
fn pick_runtime_asset(
    releases: &[super::runtime_catalog::RuntimeCatalogRelease],
    variant_id: &str,
) -> Option<(String, String)> {
    releases.iter().find_map(|release| {
        release
            .variants
            .iter()
            .find(|variant| variant.id == variant_id && !variant.sha256.is_empty())
            .map(|variant| (variant.url.clone(), variant.sha256.clone()))
    })
}

/// Resolves once `generation` is no longer the newest lifecycle intent. The
/// sender lives in the manager, so a closed channel also resolves: a dropped
/// manager can never leave a launch waiting on it.
async fn wait_for_lifecycle_change(receiver: &mut watch::Receiver<u64>, generation: u64) {
    loop {
        if *receiver.borrow_and_update() != generation {
            return;
        }
        if receiver.changed().await.is_err() {
            return;
        }
    }
}

const ROUTER_MODEL_LOAD_TIMEOUT: Duration = Duration::from_secs(180);
const ROUTER_MODEL_LOAD_POLL: Duration = Duration::from_millis(400);

/// Why `GET /models` could not be read. The distinction matters: a rejected
/// key stays rejected until the settings change, so it must reach the user at
/// once instead of looking like a slow model load.
#[derive(Debug)]
enum RouterFetchError {
    /// The engine refused the internal token (401/403).
    Unauthorized(u16),
    /// Any other non-success status.
    Http(u16),
    /// The request never completed.
    Network,
    /// The response did not match the pinned `data[].id`/`status` shape.
    Malformed,
}

impl RouterFetchError {
    fn is_unauthorized(&self) -> bool {
        matches!(self, Self::Unauthorized(_))
    }

    /// Message for the Console and the model card; the status is always named
    /// so a 401 is not mistaken for a timeout.
    fn message(&self) -> String {
        match self {
            Self::Unauthorized(status) => format!(
                "The local engine rejected the internal key (HTTP {status}). Restart the engine from the Runtime tab."
            ),
            Self::Http(status) => {
                format!("The local engine answered the model list with HTTP {status}.")
            }
            Self::Network => {
                "Cannot reach the local engine on its model port.".to_string()
            }
            Self::Malformed => {
                "The local engine returned an unexpected model list.".to_string()
            }
        }
    }
}

/// Reads every model's router state. An empty map is a valid "router lists
/// nothing"; every other outcome is a typed error so a rejected key stays
/// distinguishable from a slow load.
async fn fetch_router_models(
    client: &reqwest::Client,
    port: u16,
    token: &str,
) -> Result<HashMap<String, RouterModelState>, RouterFetchError> {
    let response = client
        .get(format!("http://127.0.0.1:{}/models", port))
        .bearer_auth(token)
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .map_err(|_| RouterFetchError::Network)?;
    let status = response.status().as_u16();
    if matches!(status, 401 | 403) {
        return Err(RouterFetchError::Unauthorized(status));
    }
    if !response.status().is_success() {
        return Err(RouterFetchError::Http(status));
    }
    let body = response
        .text()
        .await
        .map_err(|_| RouterFetchError::Network)?;
    parse_router_models(&body).ok_or(RouterFetchError::Malformed)
}

async fn post_router_model_load(
    client: &reqwest::Client,
    port: u16,
    token: &str,
    model_id: &str,
) -> Result<(), String> {
    let response = client
        .post(format!("http://127.0.0.1:{}/models/load", port))
        .bearer_auth(token)
        .timeout(Duration::from_secs(15))
        .json(&serde_json::json!({ "model": model_id }))
        .send()
        .await
        .map_err(|error| {
            format!(
                "Failed to ask the engine to load model '{}': {}",
                model_id, error
            )
        })?;
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    let body = response.text().await.unwrap_or_default();
    Err(format!(
        "The engine rejected model '{}': {}",
        model_id,
        router_error_message(&body, status.as_u16())
    ))
}

/// Last gateway publication outcome, tagged with the lifecycle revision it
/// describes. A result from an older revision must not overwrite a newer one
/// or surface as the current state.
#[derive(Debug, Clone, Default)]
pub struct PublicationState {
    revision: u64,
    message: Option<String>,
    /// Why the prompt relay is not listening, if its last start failed. Kept
    /// apart from `message` because a successful catalogue publication clears
    /// that, while a dead relay keeps dropping system prompts in silence.
    prompt_relay_error: Option<String>,
}

/// Cloneable handle the deferred catalogue poll uses to report its outcome.
#[derive(Clone)]
pub struct PublicationReporter {
    slot: Arc<Mutex<PublicationState>>,
    published: Arc<AtomicU64>,
    /// Read-only view of the lifecycle revision, so the deferred poll can tell
    /// whether the snapshot it confirmed is still the newest one before it
    /// touches caches or the Codex catalogue.
    revision_source: Arc<Mutex<RuntimeInner>>,
}

impl PublicationReporter {
    fn new(published: Arc<AtomicU64>, revision_source: Arc<Mutex<RuntimeInner>>) -> Self {
        Self {
            slot: Arc::new(Mutex::new(PublicationState::default())),
            published,
            revision_source,
        }
    }

    /// Records that `revision` reached the engine, without waiting for the
    /// catalogue. Publication is only complete after `is_current` and the
    /// gateway read-back succeeded, but the supervisor must not rewrite the
    /// same file for a revision that is already on disk.
    pub fn mark_synced(&self, revision: u64) {
        self.published.fetch_max(revision, Ordering::AcqRel);
    }

    /// True while `revision` is still the manager's newest lifecycle snapshot.
    pub fn is_current(&self, revision: u64) -> bool {
        self.revision_source
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .revision
            == revision
    }

    /// Records the prompt relay's start failure (or clears it) for the status
    /// payload. Publication results never touch this slot, so a successful
    /// catalogue write cannot hide a relay that never bound its port.
    pub fn report_prompt_relay_error(&self, error: Option<String>) {
        let mut slot = self.slot.lock().unwrap_or_else(|error| error.into_inner());
        slot.prompt_relay_error = error;
    }

    pub fn report(&self, revision: u64, message: Option<String>) {
        let mut slot = self.slot.lock().unwrap_or_else(|error| error.into_inner());
        if revision >= slot.revision {
            slot.revision = revision;
            slot.message = message;
        }
    }

    /// Marks the lifecycle dirty again so the supervisor rewrites the config on
    /// its next tick. The engine accepts the config over HTTP before its file
    /// watcher is armed, so the first write after a gateway start can be lost;
    /// retrying the same revision is the recovery, not restarting the engine.
    /// The compare-exchange keeps a newer revision published in the meantime
    /// from being published twice.
    pub fn request_resync(&self, revision: u64) {
        let _ = self
            .published
            .compare_exchange(revision, 0, Ordering::AcqRel, Ordering::Acquire);
    }
}

pub struct LocalRuntimeManager {
    inner: Arc<Mutex<RuntimeInner>>,
    installer: RuntimeInstaller,
    /// Last lifecycle revision whose effects were published to the gateway.
    published_gateway: Arc<AtomicU64>,
    /// Serializes start/stop: only the holder may spawn, kill or publish a
    /// lifecycle state. A waiting start is cancelled before it gets the lock.
    lifecycle: tokio::sync::Mutex<()>,
    /// Broadcasts the newest lifecycle generation. A start waiting on health
    /// uses it to notice immediately that a stop or another start superseded
    /// it, instead of discovering that 30 seconds later through a timeout.
    lifecycle_changed: watch::Sender<u64>,
    /// Last catalogue publication outcome, keyed by lifecycle revision.
    publication: PublicationReporter,
    /// HTTP status of the last `GET /models` refusal (0 = none). The
    /// supervisor polls every five seconds and the engine bans a caller after
    /// five rejected keys, so a repeated probe would turn one bad token into a
    /// lockout. Cleared when the lifecycle changes (`begin_lifecycle`).
    router_key_rejected: Arc<AtomicU16>,
}

struct RuntimeInner {
    child: Option<Child>,
    current_model: Option<LocalModel>,
    port: u16,
    token: String,
    state: LocalRuntimeState,
    custom_binary_path: Option<PathBuf>,
    /// Bumped on every state transition; the gateway catalogue is rewritten
    /// when this differs from `published_gateway`.
    revision: u64,
    /// When the current state was entered. The "no child process" repair only
    /// runs after a grace period, because a launch sets `Starting` a moment
    /// before the process handle exists.
    state_changed_at: Instant,
    /// Last scraped counters and when they were read. Live tokens/s are the
    /// delta against this sample; `transition` clears it on stop/restart.
    last_metrics: Option<(RuntimeMetrics, Instant)>,
    /// Byte offset in the engine log where the Console was last cleared. Reads
    /// start here, so clearing never touches the file the engine appends to.
    logs_cleared_at: u64,
    /// `userSettings` at launch; compared with the registry to show pending
    /// changes next to the model card.
    applied_settings: Option<LocalModelSettings>,
    /// Newest start/stop intent. An in-flight launch captures this value and
    /// refuses to publish Starting/Running/Failed once it no longer matches,
    /// so a superseded launch cannot overwrite the state of the one that
    /// replaced it.
    generation: u64,
}

impl RuntimeInner {
    fn transition(&mut self, state: LocalRuntimeState) {
        self.state = state;
        self.revision = self.revision.wrapping_add(1);
        self.state_changed_at = Instant::now();
        self.last_metrics = None;
    }

    /// Registry statuses that describe a live process do not survive a
    /// restart, so a `Ready` left behind by a crash is downgraded at startup
    /// instead of being advertised to the gateway.
    fn normalize_stale_statuses() {
        for model in LocalModelStore::load_registry() {
            if matches!(
                model.runtime_status,
                ModelRuntimeStatus::Loading
                    | ModelRuntimeStatus::Ready
                    | ModelRuntimeStatus::Generating
                    | ModelRuntimeStatus::Unloading
            ) {
                if let Err(error) =
                    LocalModelStore::update_model_status(&model.id, ModelRuntimeStatus::Installed)
                {
                    eprintln!(
                        "local ai: could not clear the stale status of {}: {error}",
                        model.id
                    );
                }
            }
        }
    }

    /// Reaps a child that exited on its own and repairs impossible states
    /// (`Running` with no process, `Starting` with nothing to start). Returns
    /// the model whose registry status has to change, so the caller can do the
    /// filesystem write outside this lock.
    fn settle(&mut self) -> Option<(String, ModelRuntimeStatus)> {
        let exited = match self.child.as_mut() {
            Some(child) => match child.try_wait() {
                Ok(Some(status)) => Some(status.to_string()),
                Ok(None) => None,
                // The handle is unusable; treat it as gone rather than
                // reporting a process we cannot observe.
                Err(error) => Some(format!("unobservable process: {}", error)),
            },
            None => None,
        };

        if let Some(status) = exited {
            self.child = None;
            forget_engine_pid();
            super::system_prompt_proxy::set_upstream(0);
            // Keep `current_model` so `failedModelId` still names the card
            // that has to show the error.
            let model_id = self.current_model.as_ref().map(|model| model.id.clone());
            // The exit code alone cannot tell OOM, a busy port and a broken
            // GGUF apart; the engine already wrote the reason to its log.
            let detail = read_log_tail(&local_logs_dir().join("llama-server.log"), 12)
                .ok()
                .filter(|lines| !lines.is_empty())
                .map(|lines| {
                    let text = lines.join("\n");
                    let text: String = text
                        .chars()
                        .rev()
                        .take(2000)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect();
                    format!("\n{}", text)
                })
                .unwrap_or_default();
            let error = format!("llama-server exited unexpectedly ({}){}", status, detail);
            self.transition(LocalRuntimeState::Failed { error });
            self.applied_settings = None;
            return model_id.map(|id| (id, ModelRuntimeStatus::Error));
        }

        // A launch publishes `Starting` before the OS process exists, so this
        // repair waits out that window instead of failing a healthy start.
        let impossible = matches!(
            self.state,
            LocalRuntimeState::Running { .. } | LocalRuntimeState::Starting { .. }
        ) && self.child.is_none()
            && self.state_changed_at.elapsed() > Duration::from_secs(5);
        if impossible {
            forget_engine_pid();
            let model_id = self.current_model.as_ref().map(|model| model.id.clone());
            let error = "llama-server is not running".to_string();
            self.transition(LocalRuntimeState::Failed { error });
            self.applied_settings = None;
            return model_id.map(|id| (id, ModelRuntimeStatus::Error));
        }

        None
    }
}

/// Everything the status payload needs, copied while the lock is held.
///
/// `get_status` used to hold this mutex and call `binary_path()`, which locks
/// the same non-reentrant `std::sync::Mutex` — the whole Local AI tab hung.
/// The snapshot is taken first and the payload is built after the guard is
/// dropped; `status_payload` is a free function so a test can prove that
/// building it never touches the runtime.
#[derive(Debug, Clone)]
struct StatusSnapshot {
    state: LocalRuntimeState,
    port: u16,
    current_model: Option<RuntimeModelRef>,
    token: String,
    revision: u64,
    applied_settings: Option<LocalModelSettings>,
}

impl StatusSnapshot {
    fn capture(inner: &RuntimeInner) -> Self {
        Self {
            state: inner.state.clone(),
            port: inner.port,
            current_model: inner
                .current_model
                .as_ref()
                .map(RuntimeModelRef::from_model),
            token: inner.token.clone(),
            revision: inner.revision,
            applied_settings: inner.applied_settings.clone(),
        }
    }
}

fn status_payload(
    snapshot: StatusSnapshot,
    binary_path: Option<String>,
    publication_error: Option<String>,
) -> RuntimeStatusPayload {
    let is_running = matches!(snapshot.state, LocalRuntimeState::Running { .. });
    let starting_model_id = match &snapshot.state {
        LocalRuntimeState::Starting { model_id } => Some(model_id.clone()),
        _ => None,
    };
    let model_id = snapshot
        .current_model
        .as_ref()
        .map(|model| model.id.clone());
    let failed_model_id = match &snapshot.state {
        LocalRuntimeState::Failed { .. } => model_id.clone(),
        _ => None,
    };
    let error = match &snapshot.state {
        LocalRuntimeState::Failed { error } => Some(error.clone()),
        _ => None,
    };

    RuntimeStatusPayload {
        state: snapshot.state,
        port: snapshot.port,
        model_id: model_id.clone(),
        current_model: snapshot.current_model,
        internal_token: snapshot.token,
        is_running,
        is_starting: starting_model_id.is_some(),
        starting_model_id,
        failed_model_id,
        error,
        binary_path,
        revision: snapshot.revision,
        applied_settings: snapshot.applied_settings,
        publication_error,
    }
}

impl Default for LocalRuntimeManager {
    fn default() -> Self {
        Self::new()
    }
}

impl LocalRuntimeManager {
    pub fn new() -> Self {
        // A crash skips the orderly stop. Reap the engine recorded by the last
        // run before reporting any status, otherwise its model stays resident.
        // Not under `cargo test`: the tests build managers against the real
        // metadata directory, and a test run next to a live app would kill the
        // engine that app is using.
        #[cfg(not(test))]
        reap_orphan_engine();
        RuntimeInner::normalize_stale_statuses();
        let published_gateway = Arc::new(AtomicU64::new(0));
        let inner = Arc::new(Mutex::new(RuntimeInner {
            child: None,
            current_model: None,
            port: 18318,
            token: get_or_create_internal_token(),
            state: LocalRuntimeState::Stopped,
            custom_binary_path: load_custom_binary_path(),
            // Start dirty: the first status poll republishes the gateway
            // catalogue from the normalized registry, so a model that was
            // `Ready` when the app last crashed is not advertised.
            revision: 1,
            state_changed_at: Instant::now(),
            last_metrics: None,
            logs_cleared_at: 0,
            applied_settings: None,
            generation: 0,
        }));
        Self {
            installer: RuntimeInstaller::new(),
            published_gateway: published_gateway.clone(),
            lifecycle: tokio::sync::Mutex::new(()),
            lifecycle_changed: {
                let (sender, _receiver) = watch::channel(0);
                sender
            },
            publication: PublicationReporter::new(published_gateway, inner.clone()),
            inner,
            router_key_rejected: Arc::new(AtomicU16::new(0)),
        }
    }

    /// Current lifecycle revision. Every start/stop/crash/error/unload bumps
    /// it, which is what drives the gateway rewrite.
    pub fn revision(&self) -> u64 {
        self.inner
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .revision
    }

    /// `Some(revision)` when the gateway has not seen the current lifecycle
    /// state yet. `None` means the published catalogue is current.
    pub fn pending_gateway_revision(&self) -> Option<u64> {
        let revision = self.revision();
        (revision != self.published_gateway.load(Ordering::Acquire)).then_some(revision)
    }

    pub fn mark_gateway_synced(&self, revision: u64) {
        self.publication.mark_synced(revision);
    }

    /// Handle for the deferred catalogue poll, which runs after the command
    /// that triggered the rewrite has returned.
    pub fn publication_reporter(&self) -> PublicationReporter {
        self.publication.clone()
    }

    /// The publication error only applies while the lifecycle revision it was
    /// recorded for is still current; an older attempt must not make a healthy
    /// runtime look broken.
    pub(crate) fn current_publication_error(&self) -> Option<String> {
        let revision = self.revision();
        let slot = self
            .publication
            .slot
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let mut message = if slot.revision == revision {
            slot.message.clone()
        } else {
            None
        };
        if let Some(relay) = slot.prompt_relay_error.as_deref() {
            let relay = format!("Prompt relay did not start: {relay}");
            message = Some(match message {
                Some(message) => format!("{message} {relay}"),
                None => relay,
            });
        }
        drop(slot);
        // A rejected internal key is a standing condition, not a one-off
        // publication result: `report` clears `message` on the next successful
        // catalogue write, so it is surfaced here instead. The latch keeps the
        // supervisor from probing a key the engine already refuses.
        let rejected = self.router_key_rejected.load(Ordering::Acquire);
        if rejected != 0 {
            let notice = format!(
                "The local engine rejected the internal key (HTTP {rejected}). Restart the engine from the Runtime tab."
            );
            message = Some(match message {
                Some(message) => format!("{message} {notice}"),
                None => notice,
            });
        }
        message
    }

    /// Sets the lifecycle revision without running a transition, so the
    /// publication tests can start from a dirty snapshot.
    #[cfg(test)]
    pub(crate) fn set_revision_for_test(&self, revision: u64) {
        self.inner
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .revision = revision;
    }

    /// Side-effect free manager for the regression tests: no token file, no
    /// registry rewrite, no binary lookup on the real machine.
    #[cfg(test)]
    pub(crate) fn for_test() -> Self {
        let published_gateway = Arc::new(AtomicU64::new(0));
        let inner = Arc::new(Mutex::new(RuntimeInner {
            child: None,
            current_model: None,
            port: 18318,
            token: "test-token".to_string(),
            state: LocalRuntimeState::Stopped,
            custom_binary_path: None,
            revision: 0,
            state_changed_at: Instant::now(),
            last_metrics: None,
            logs_cleared_at: 0,
            applied_settings: None,
            generation: 0,
        }));
        Self {
            installer: RuntimeInstaller::new(),
            published_gateway: published_gateway.clone(),
            lifecycle: tokio::sync::Mutex::new(()),
            lifecycle_changed: {
                let (sender, _receiver) = watch::channel(0);
                sender
            },
            publication: PublicationReporter::new(published_gateway, inner.clone()),
            inner,
            router_key_rejected: Arc::new(AtomicU16::new(0)),
        }
    }

    /// Persists the explicit choice so a runtime installed into
    /// `runtime/packages/<id>` stays selected after a restart instead of
    /// falling back to PATH.
    /// Records the engine the user picked. The path is validated before it is
    /// stored: a missing file or a non-x64 image used to be accepted silently,
    /// the launch then fell back to another engine, and the UI still showed the
    /// path the user typed. The file is written first so a failed write cannot
    /// leave the in-memory choice disagreeing with the persisted one.
    ///
    /// Switching the path under a running engine used to leave `Running`
    /// describing a binary the stored state no longer named. Validation happens
    /// first (a rejected path must not stop a healthy runtime), then the engine
    /// is stopped before the new path is persisted.
    pub async fn set_custom_binary_path(&self, path: Option<PathBuf>) -> Result<(), String> {
        let path = path.filter(|candidate| !candidate.as_os_str().is_empty());
        if let Some(candidate) = path.as_ref() {
            if !candidate.is_file() {
                return Err(format!(
                    "The engine path {} is not a file.",
                    candidate.display()
                ));
            }
            #[cfg(windows)]
            validate_pe_x64(candidate)?;
        }
        let (changed, live) = {
            let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            (
                inner.custom_binary_path.as_deref() != path.as_deref(),
                inner.child.is_some()
                    || matches!(
                        &inner.state,
                        LocalRuntimeState::Starting { .. } | LocalRuntimeState::Running { .. }
                    ),
            )
        };
        if changed && live {
            self.stop().await;
        }
        let file = custom_binary_path_file();
        match path.as_ref() {
            Some(candidate) => {
                if let Some(parent) = file.parent() {
                    fs::create_dir_all(parent)
                        .map_err(|e| format!("Cannot create the settings folder: {e}"))?;
                }
                fs::write(&file, candidate.to_string_lossy().as_bytes())
                    .map_err(|e| format!("Cannot save the engine path: {e}"))?;
            }
            None => {
                if file.exists() {
                    fs::remove_file(&file)
                        .map_err(|e| format!("Cannot clear the engine path: {e}"))?;
                }
            }
        }
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.custom_binary_path = path;
        Ok(())
    }

    /// The Mac build ships `llama-server` inside the app bundle. Windows has
    /// no bundled engine, so the first model start fetches the official
    /// llama.cpp build the Runtime tab lists, verifies its SHA-256 and records
    /// the installed binary. A fresh install must never fail with
    /// "llama-server executable not found"; only a failed download reports an
    /// error, and that error names the retry path.
    pub async fn ensure_engine(&self) -> Result<(), String> {
        if self.binary_path().is_some() {
            return Ok(());
        }

        let installing = *self
            .installer
            .active
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if !installing {
            let releases = super::runtime_catalog::fetch_catalog()
                .await
                .map_err(|error| format!("Cannot list the official llama.cpp builds: {}", error))?;
            let variant = preferred_runtime_variant();
            let (url, sha256) = pick_runtime_asset(&releases, variant).ok_or_else(|| {
                format!(
                    "The official llama.cpp catalog has no {} build for Windows.",
                    variant
                )
            })?;
            self.start_install(&url, &sha256)?;
        }

        let deadline = Instant::now() + ENGINE_INSTALL_TIMEOUT;
        loop {
            let status = self.installer.status();
            match status.stage {
                RuntimeInstallStage::Done => {
                    let binary = status.binary_path.ok_or_else(|| {
                        "The installed runtime did not report a llama-server path.".to_string()
                    })?;
                    self.set_custom_binary_path(Some(PathBuf::from(binary)))
                        .await?;
                    return Ok(());
                }
                RuntimeInstallStage::Failed => {
                    return Err(status
                        .error
                        .unwrap_or_else(|| "The llama.cpp runtime download failed.".to_string()))
                }
                RuntimeInstallStage::Cancelled => {
                    return Err("The llama.cpp runtime download was cancelled.".to_string())
                }
                _ => {}
            }
            if Instant::now() > deadline {
                return Err(
                    "The llama.cpp runtime download timed out. Check the connection and retry from the Runtime tab."
                        .to_string(),
                );
            }
            tokio::time::sleep(ENGINE_INSTALL_POLL).await;
        }
    }

    pub fn binary_path(&self) -> Option<PathBuf> {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(ref custom) = inner.custom_binary_path {
            if custom.is_file() {
                return Some(custom.clone());
            }
        }

        // 1. Check local runtime dir (%LOCALAPPDATA%\MelonTools\runtime\llama-server.exe)
        let standard = llama_server_exe_path();
        if standard.is_file() {
            return Some(standard);
        }

        // 2. Installed runtime packages. The persisted choice can be gone
        // while `runtime/packages/<id>` survives, so a downloaded engine keeps
        // working after a restart without another download.
        if let Some(packaged) = installed_package_binary() {
            return Some(packaged);
        }

        // 3. Check PATH
        if let Some(paths) = std::env::var_os("PATH") {
            for p in std::env::split_paths(&paths) {
                let candidate1 = p.join("llama-server.exe");
                if candidate1.is_file() {
                    return Some(candidate1);
                }
                let candidate2 = p.join("llama-server");
                if candidate2.is_file() {
                    return Some(candidate2);
                }
            }
        }

        None
    }

    pub fn port(&self) -> u16 {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).port
    }

    pub fn token(&self) -> String {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .token
            .clone()
    }

    /// Writes the INI the router reads: one section per installed model with
    /// its own context, KV type, offload and reasoning flag.
    fn write_models_preset(
        models_dir: &std::path::Path,
        backend: InferenceBackend,
        cpu_cores: usize,
    ) -> Result<std::path::PathBuf, String> {
        let mut lines: Vec<String> = Vec::new();
        lines.push(
            "# Generated by Melon Tools. Do not edit: rewritten on every launch.".to_string(),
        );

        for model in LocalModelStore::load_registry() {
            let file = models_dir.join(model.files.first().cloned().unwrap_or_default());
            if !file.exists() {
                continue;
            }
            lines.push(String::new());
            lines.push(format!("[{}]", model.id));
            lines.push(format!("model = {}", file.display()));
            lines.push(format!("alias = {}", model.id));
            // Structured tool calling uses the model's Jinja chat template.
            lines.push("jinja = true".to_string());
            lines.push(format!("ctx-size = {}", model.user_settings.context_length));
            lines.push(format!("batch-size = {}", model.user_settings.batch_size));
            lines.push(if backend != InferenceBackend::Cpu {
                format!(
                    "n-gpu-layers = {}",
                    model.user_settings.gpu_offload_layers.unwrap_or(99)
                )
            } else {
                "n-gpu-layers = 0".to_string()
            });
            lines.push(format!(
                "flash-attn = {}",
                if model.user_settings.flash_attention {
                    "on"
                } else {
                    "off"
                }
            ));
            if let Some(template) = model.user_settings.chat_template.as_ref() {
                if !template.is_empty() && template != "auto" {
                    lines.push(format!("chat-template = {}", template));
                }
            }
            lines.push(format!(
                "reasoning = {}",
                if model.user_settings.is_reasoning_on() {
                    "on"
                } else {
                    "off"
                }
            ));
            lines.push(format!(
                "cache-type-k = {}",
                model.user_settings.kv_cache_type
            ));
            lines.push(format!(
                "cache-type-v = {}",
                model.user_settings.kv_cache_type
            ));
            lines.push(format!(
                "threads = {}",
                model.user_settings.cpu_threads.unwrap_or(cpu_cores)
            ));
        }

        if lines.len() <= 1 {
            return Err("No installed model files to serve.".to_string());
        }

        let dir = local_metadata_dir();
        // First launch on a clean Windows profile has no metadata directory yet.
        std::fs::create_dir_all(&dir)
            .map_err(|e| format!("Failed to create models preset directory: {}", e))?;
        let path = dir.join("models.ini");
        std::fs::write(&path, lines.join("\n") + "\n")
            .map_err(|e| format!("Failed to write models preset: {}", e))?;
        Ok(path)
    }

    /// Parallel slots for the engine. The saved setting wins; the environment
    /// variable stays as a development override, then the macOS default of 1.
    fn parallel_requests() -> usize {
        if let Some(value) = std::env::var("MELON_LOCAL_PARALLEL")
            .ok()
            .and_then(|v| v.parse::<usize>().ok())
        {
            return value.clamp(1, 16);
        }
        crate::settings::load().local_parallel_requests.clamp(1, 16) as usize
    }

    fn idle_unload_seconds() -> u64 {
        if let Some(value) = std::env::var("MELON_LOCAL_IDLE_UNLOAD")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
        {
            return value;
        }
        crate::settings::load().local_idle_unload_seconds as u64
    }

    /// Models the engine may keep loaded at once. macOS exposes the same
    /// choice as 1, 2 or 3 and recommends 1.
    fn models_max_concurrent() -> usize {
        crate::settings::load().local_models_max.clamp(1, 3) as usize
    }

    /// One snapshot of the runtime state.
    ///
    /// The lock is released before `binary_path()` is called: it takes the
    /// same non-reentrant `Mutex`, so doing it under the guard deadlocked
    /// every status poll (and with it Start/Stop/metrics/delete).
    pub fn get_status(&self) -> RuntimeStatusPayload {
        let snapshot = {
            let mut inner = self.inner.lock().unwrap_or_else(|error| error.into_inner());
            if let Some((model_id, status)) = inner.settle() {
                if let Err(error) = LocalModelStore::update_model_status(&model_id, status) {
                    eprintln!("local ai: could not publish the exit of {model_id}: {error}");
                }
                // A crashed router may have loaded models besides current_model.
                // Do not leave any of those routes advertised after child exit.
                RuntimeInner::normalize_stale_statuses();
            }
            StatusSnapshot::capture(&inner)
        };

        // Safe now: the guard above is gone.
        let binary_path = self
            .binary_path()
            .map(|path| path.to_string_lossy().to_string());
        let publication_error = self.current_publication_error();
        status_payload(snapshot, binary_path, publication_error)
    }

    /// The listener is dropped immediately, so this only rules out the ports
    /// held right now; the spawn below can still lose the race. What it must
    /// not do is return `start` when every candidate is taken: the engine then
    /// failed with a bare exit code instead of naming the port conflict.
    pub fn find_available_port(start: u16) -> Result<u16, String> {
        for candidate in start..(start + 31) {
            if let Ok(listener) = TcpListener::bind(("127.0.0.1", candidate)) {
                drop(listener);
                return Ok(candidate);
            }
        }
        Err(format!(
            "No free loopback port between {start} and {}. Close the program holding them and retry.",
            start + 30
        ))
    }

    pub fn install_status(&self) -> RuntimeInstallStatus {
        self.installer.status()
    }

    /// Starts a background HTTP install of a ZIP runtime package. The archive
    /// digest is mandatory and the package is published under its own
    /// `runtime/packages/<id>` directory; the active runtime is never
    /// overwritten.
    pub fn start_install(&self, url: &str, sha256: &str) -> Result<String, String> {
        self.installer.start(url, sha256)
    }

    pub fn cancel_install(&self) {
        self.installer.cancel();
    }

    /// Reads live metrics for the model the engine currently serves. Only a
    /// running engine has a model to name; a stopped one is not an error the
    /// UI should surface, so callers poll only while `is_running`.
    pub async fn metrics(&self) -> Result<RuntimeMetrics, String> {
        let (port, token, model_id) = {
            let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            match &inner.state {
                LocalRuntimeState::Running { port, model_id } => {
                    (*port, inner.token.clone(), model_id.clone())
                }
                LocalRuntimeState::Starting { .. } => {
                    return Err("The local engine is still starting.".to_string())
                }
                _ => return Err("The local engine is not running.".to_string()),
            }
        };
        let mut current = fetch_runtime_metrics(port, &token, &model_id).await?;
        let now = Instant::now();
        {
            let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            let same_model = matches!(
                &inner.state,
                LocalRuntimeState::Running { model_id: running, .. } if running == &model_id
            );
            if same_model {
                if let Some((previous, at)) = inner.last_metrics.as_ref() {
                    apply_live_rates(
                        &mut current,
                        previous,
                        now.duration_since(*at).as_secs_f64(),
                    );
                }
                inner.last_metrics = Some((current.clone(), now));
            } else {
                // A restart or a stop invalidates the counters; the next sample
                // must not compute a delta across two processes.
                inner.last_metrics = None;
            }
        }
        Ok(current)
    }

    /// Tail of the engine log for the Console pane, starting after the last
    /// "Clear". The read is byte-capped, so polling a huge log stays cheap.
    pub fn logs(&self, max_lines: usize) -> Result<Vec<String>, String> {
        let path = local_logs_dir().join("llama-server.log");
        let after = self
            .inner
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .logs_cleared_at;
        read_log_tail_after(&path, max_lines, after)
    }

    /// Hides the current Console output. The file is left alone: the running
    /// engine owns a write handle and truncating under it would leave a gap.
    pub fn clear_logs(&self) -> Result<(), String> {
        let path = local_logs_dir().join("llama-server.log");
        let len = fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0);
        let mut inner = self.inner.lock().unwrap_or_else(|error| error.into_inner());
        inner.logs_cleared_at = len;
        Ok(())
    }

    /// Claims the newest lifecycle generation. Waking the watchers before the
    /// new operation takes the lifecycle lock is what cancels a start that is
    /// still sleeping in its health loop: it sees the bump and abandons its
    /// child instead of publishing Running/Failed for a superseded launch.
    fn begin_lifecycle(&self) -> (u64, watch::Receiver<u64>) {
        let generation = {
            let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.generation = inner.generation.wrapping_add(1);
            // Bump and notify under the same lock: two racing starts must not
            // deliver an older generation last and cancel the newer one.
            self.lifecycle_changed.send_replace(inner.generation);
            inner.generation
        };
        // A start/stop may also have fixed the key, so allow one probe again.
        self.router_key_rejected.store(0, Ordering::Release);
        (generation, self.lifecycle_changed.subscribe())
    }

    fn is_current_generation(&self, generation: u64) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .generation
            == generation
    }

    /// Publishes `state` only when `generation` is still the newest intent.
    /// Returns false when the caller was superseded and must not publish.
    ///
    /// Only the tests drive it directly now: production paths publish through
    /// `publish_ready`/`fail_launch`, which own the same lock.
    #[cfg_attr(not(test), allow(dead_code))]
    fn transition_if_current(&self, generation: u64, state: LocalRuntimeState) -> bool {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            return false;
        }
        inner.transition(state);
        true
    }

    fn update_model_status_if_current(
        &self,
        generation: u64,
        model_id: &str,
        status: ModelRuntimeStatus,
    ) {
        // Check and write under the same lock `begin_lifecycle` bumps: a stop
        // that wins the lock first makes this write a no-op, so it cannot
        // leave a stale `Ready` after the newer generation owns the engine.
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            return;
        }
        if let Err(error) = LocalModelStore::update_model_status(model_id, status) {
            eprintln!("local ai: could not persist the status of {model_id}: {error}");
        }
    }

    fn superseded_message() -> String {
        "Local AI start was superseded by a newer start/stop request.".to_string()
    }

    /// Kills a process this launch owns after it was superseded, so a start
    /// that lost the race never leaves an orphan behind. Only the lifecycle
    /// holder can call it, which guarantees the child is its own.
    async fn discard_child(&self) {
        let child = {
            let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.child.take()
        };
        if let Some(mut child) = child {
            terminate_engine_async(&mut child).await;
            forget_engine_pid();
        }
    }

    /// Kills the engine this manager owns and publishes `Stopped`. The caller
    /// must hold `lifecycle` and must still own the current generation.
    async fn stop_locked(&self) {
        // The kill is awaited without holding the state lock: a wedged engine
        // takes up to three seconds and the supervisor polls the status every
        // five, so it must not block on this mutex.
        let child = {
            let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            inner.child.take()
        };
        if let Some(mut child) = child {
            terminate_engine_async(&mut child).await;
            forget_engine_pid();
        }
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        // The relay keeps listening so the gateway config stays valid, but it
        // must answer 503 "not running" instead of dialling the dead port.
        super::system_prompt_proxy::set_upstream(0);
        // Reset every warm router model before publishing the Stopped revision,
        // for the same reason Ready is persisted before publishing Running.
        if let Some(model) = inner.current_model.as_ref() {
            if let Err(error) =
                LocalModelStore::update_model_status(&model.id, ModelRuntimeStatus::Installed)
            {
                eprintln!(
                    "local ai: could not clear the status of {} on stop: {error}",
                    model.id
                );
            }
        }
        RuntimeInner::normalize_stale_statuses();
        inner.current_model = None;
        inner.applied_settings = None;
        inner.transition(LocalRuntimeState::Stopped);
    }

    pub async fn stop(&self) {
        let (generation, _cancelled) = self.begin_lifecycle();
        let _guard = self.lifecycle.lock().await;
        // A newer start was requested while this stop waited for the lock. It
        // owns the engine now, so this stop must not kill that process.
        if !self.is_current_generation(generation) {
            return;
        }
        self.stop_locked().await;
    }

    /// Publishes a terminal launch failure only for the current generation.
    /// A superseded launch returns false and leaves the new state alone.
    async fn fail_launch(&self, generation: u64, model_id: &str, error: &str) -> bool {
        let child = {
            let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            if inner.generation != generation {
                return false;
            }
            inner.child.take()
        };
        if let Some(mut child) = child {
            terminate_engine_async(&mut child).await;
            forget_engine_pid();
        }
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            return false;
        }
        inner.applied_settings = None;
        inner.transition(LocalRuntimeState::Failed {
            error: error.to_string(),
        });
        drop(inner);
        self.update_model_status_if_current(generation, model_id, ModelRuntimeStatus::Error);
        true
    }

    /// Publishes a launch failure through [`Self::fail_launch`] and returns the
    /// message the command reports. Early `?` paths used to return bare `Err`
    /// after the previous engine was stopped, so the failure never reached the
    /// runtime state or the model status.
    async fn fail_launch_error(&self, generation: u64, model_id: &str, error: String) -> String {
        if !self.fail_launch(generation, model_id, &error).await {
            return Self::superseded_message();
        }
        error
    }

    /// Returns an error when this launch's process is gone or exited while a
    /// long model load was in flight.
    fn ensure_child_alive(&self, generation: u64) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            return Err(Self::superseded_message());
        }
        let Some(child) = inner.child.as_mut() else {
            return Err("llama-server is no longer running.".to_string());
        };
        match child.try_wait() {
            Ok(Some(status)) => {
                inner.child = None;
                Err(format!(
                    "llama-server exited while loading the model with status {}",
                    status
                ))
            }
            Ok(None) => Ok(()),
            Err(error) => Err(format!("Cannot check llama-server process: {}", error)),
        }
    }

    /// Waits until `GET /models` reports this model as `loaded`. Health only
    /// proves the router answers; this is what proves the weights are resident.
    async fn load_model_into_router(
        &self,
        generation: u64,
        cancelled: &mut watch::Receiver<u64>,
        client: &reqwest::Client,
        port: u16,
        token: &str,
        model_id: &str,
    ) -> Result<(), String> {
        let already_loaded = match tokio::select! {
            _ = wait_for_lifecycle_change(cancelled, generation) => {
                return Err(Self::superseded_message());
            }
            states = fetch_router_models(client, port, token) => states,
        } {
            Ok(states) => Some(states),
            Err(error) if error.is_unauthorized() => {
                // A rejected key fails every following call the same way; report
                // it now instead of waiting out the load timeout, and latch it
                // so the supervisor does not probe a key the engine bans after
                // five attempts.
                if let RouterFetchError::Unauthorized(status) = &error {
                    self.router_key_rejected.store(*status, Ordering::Release);
                }
                return Err(error.message());
            }
            Err(_) => None,
        };
        if already_loaded
            .as_ref()
            .is_some_and(|states| states.get(model_id) == Some(&RouterModelState::Loaded))
        {
            return Ok(());
        }

        tokio::select! {
            _ = wait_for_lifecycle_change(cancelled, generation) => {
                return Err(Self::superseded_message());
            }
            result = post_router_model_load(client, port, token, model_id) => {
                result?;
            }
        }

        let deadline = Instant::now() + ROUTER_MODEL_LOAD_TIMEOUT;
        loop {
            if !self.is_current_generation(generation) {
                return Err(Self::superseded_message());
            }
            self.ensure_child_alive(generation)?;

            let states = match tokio::select! {
                _ = wait_for_lifecycle_change(cancelled, generation) => {
                    return Err(Self::superseded_message());
                }
                states = fetch_router_models(client, port, token) => states,
            } {
                Ok(states) => Some(states),
                Err(error) if error.is_unauthorized() => {
                    if let RouterFetchError::Unauthorized(status) = &error {
                        self.router_key_rejected.store(*status, Ordering::Release);
                    }
                    return Err(error.message());
                }
                Err(_) => None,
            };
            if let Some(states) = states {
                match states.get(model_id) {
                    Some(RouterModelState::Loaded) => return Ok(()),
                    Some(RouterModelState::Failed) => {
                        return Err(format!("The engine rejected model '{}'.", model_id))
                    }
                    _ => {}
                }
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "The engine did not finish loading model '{}' within {} seconds.",
                    model_id,
                    ROUTER_MODEL_LOAD_TIMEOUT.as_secs()
                ));
            }
            tokio::select! {
                _ = tokio::time::sleep(ROUTER_MODEL_LOAD_POLL) => {}
                _ = wait_for_lifecycle_change(cancelled, generation) => {
                    return Err(Self::superseded_message());
                }
            }
        }
    }

    pub async fn load_model(&self, model_id: &str) -> Result<(), String> {
        let (generation, mut cancelled) = self.begin_lifecycle();
        let models_dir = LocalModelStore::models_dir();
        let _ = fs::create_dir_all(&models_dir);
        // The hardware probe shells out to PowerShell and can take seconds, so
        // it runs before the lifecycle lock and off the async worker. A stop or
        // a newer start during the probe bumps the generation and is caught by
        // the check right after the lock.
        let hw = super::hardware::detect_hardware_async(Some(models_dir.clone())).await;
        let _guard = self.lifecycle.lock().await;
        if !self.is_current_generation(generation) {
            return Err(Self::superseded_message());
        }
        // The registry read happens after the generation is claimed: a stop
        // that arrives first invalidates this launch before it can touch the
        // running engine.
        let model = LocalModelStore::get_model(model_id)
            .ok_or_else(|| format!("Model '{}' not found in registry", model_id))?;
        if !self.is_current_generation(generation) {
            return Err(Self::superseded_message());
        }
        // Replaces the old public `stop()` call: this already runs under the
        // lifecycle lock, so no concurrent start can interleave with the reset.
        self.stop_locked().await;

        let Some(bin) = self.binary_path() else {
            let error = "llama-server executable not found. Please place llama-server in the runtime directory or specify its path in settings.".to_string();
            return Err(self.fail_launch_error(generation, &model.id, error).await);
        };

        let models_root = match fs::canonicalize(&models_dir) {
            Ok(root) => root,
            Err(error) => {
                let error = format!("Cannot resolve the models directory: {error}");
                return Err(self.fail_launch_error(generation, &model.id, error).await);
            }
        };
        let requested = match model.files.first() {
            Some(first) => {
                let path = Path::new(first);
                if path.is_absolute() {
                    path.to_path_buf()
                } else {
                    models_dir.join(path)
                }
            }
            None => {
                let error = "Model has no files specified".to_string();
                return Err(self.fail_launch_error(generation, &model.id, error).await);
            }
        };
        // `join` does not normalise `..`, and a directory satisfies `exists()`.
        // Both used to reach the preset and fail later as an engine exit code.
        let model_file_path = fs::canonicalize(&requested).map_err(|_| {
            self.update_model_status_if_current(
                generation,
                &model.id,
                ModelRuntimeStatus::NotInstalled,
            );
            format!("Model file does not exist: {}", requested.display())
        })?;
        if !model_file_path.is_file() {
            let error = format!("Model path is not a file: {}", model_file_path.display());
            return Err(self.fail_launch_error(generation, &model.id, error).await);
        }
        if !model_file_path.starts_with(&models_root) {
            let error = format!(
                "Model file is outside the models directory: {}",
                model_file_path.display()
            );
            return Err(self.fail_launch_error(generation, &model.id, error).await);
        }

        // `mut` because a taken port is retried on the next candidate below.
        let mut port = match Self::find_available_port(18318) {
            Ok(port) => port,
            Err(error) => return Err(self.fail_launch_error(generation, &model.id, error).await),
        };
        let token = get_or_create_internal_token();

        {
            let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            if inner.generation != generation {
                return Err(Self::superseded_message());
            }
            inner.port = port;
            inner.token = token.clone();
            inner.transition(LocalRuntimeState::Starting {
                model_id: model.id.clone(),
            });
            inner.current_model = Some(model.clone());
        }

        if !self.is_current_generation(generation) {
            return Err(Self::superseded_message());
        }
        self.update_model_status_if_current(generation, &model.id, ModelRuntimeStatus::Loading);

        // Router mode: the engine serves every installed model and loads them
        // on demand, matching the macOS implementation (§4.3).
        let preset_path =
            match Self::write_models_preset(&models_dir, hw.recommended_backend, hw.cpu_cores) {
                Ok(path) => path,
                Err(error) => {
                    // The state is already Starting: returning without a
                    // terminal transition would leave the UI waiting forever.
                    return Err(self.fail_launch_error(generation, &model.id, error).await);
                }
            };
        let parallel = Self::parallel_requests();
        let idle = Self::idle_unload_seconds();
        let log_file_path = local_logs_dir().join("llama-server.log");
        let log_sink =
            match EngineLogSink::open(&log_file_path, ENGINE_LOG_MAX_BYTES, ENGINE_LOG_BACKUPS) {
                Ok(sink) => Arc::new(Mutex::new(sink)),
                Err(error) => {
                    return Err(self.fail_launch_error(generation, &model.id, error).await);
                }
            };

        // Short timeout and no proxy: a half-open socket must not stall startup.
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_millis(1500))
            .build()
            .unwrap_or_default();

        // `find_available_port` only proves the port was free when it probed;
        // another process can take it before llama-server binds. That used to
        // surface as a 30-second "exited prematurely" failure, so a bind
        // failure is retried on the next candidate port instead.
        let mut port_attempts = ENGINE_PORT_ATTEMPTS;
        let port = 'attempt: loop {
            save_runtime_port(port);
            {
                let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
                if inner.generation != generation {
                    return Err(Self::superseded_message());
                }
                inner.port = port;
            }
            // The gateway is pointed at the prompt relay, which forwards to this
            // port. Started before the config is written so the URL is live.
            super::system_prompt_proxy::set_upstream(port);
            // A relay that cannot bind leaves the gateway config pointing at a
            // dead socket and quietly drops every stored system prompt; release
            // builds hide stderr, so surface the reason next to the publication
            // error.
            let relay_port = super::system_prompt_proxy::ensure_started();
            self.publication.report_prompt_relay_error(
                (relay_port == 0)
                    .then(super::system_prompt_proxy::last_error)
                    .flatten(),
            );

            let mut args = vec![
                "--host".to_string(),
                "127.0.0.1".to_string(),
                "--port".to_string(),
                port.to_string(),
                "--api-key".to_string(),
                token.clone(),
                "--models-preset".to_string(),
                preset_path.to_string_lossy().to_string(),
                "--models-max".to_string(),
                Self::models_max_concurrent().to_string(),
                "--metrics".to_string(),
            ];
            if parallel > 1 {
                args.push("--parallel".to_string());
                args.push(parallel.to_string());
            }
            if idle > 0 {
                args.push("--sleep-idle-seconds".to_string());
                args.push(idle.to_string());
            }

            // Only bytes written by this attempt may be read as its bind error.
            let log_offset = fs::metadata(&log_file_path)
                .map(|metadata| metadata.len())
                .unwrap_or(0);

            let mut cmd = Command::new(&bin);
            cmd.args(&args)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());

            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                const CREATE_NO_WINDOW: u32 = 0x08000000;
                cmd.creation_flags(CREATE_NO_WINDOW);
            }

            #[cfg(unix)]
            {
                // Own group, so `terminate_engine_async` can signal the router
                // and every model child it forks with a single killpg.
                use std::os::unix::process::CommandExt;
                cmd.process_group(0);
            }

            let mut child = match cmd.spawn() {
                Ok(child) => child,
                Err(error) => {
                    let error = format!("Failed to spawn llama-server: {error}");
                    return Err(self.fail_launch_error(generation, &model.id, error).await);
                }
            };
            // Same kill-on-close job as the gateway: an app crash or the
            // updater's exit must not leave the engine holding RAM and its port.
            let pid = child.id();
            if pid != 0 {
                if let Err(error) = crate::engine_job::assign(pid) {
                    terminate_engine_async(&mut child).await;
                    let message = format!("Cannot contain the Local AI process safely: {error}");
                    return Err(self.fail_launch_error(generation, &model.id, message).await);
                }
                remember_engine_pid(pid);
            }
            if let Some(stdout) = child.stdout.take() {
                pump_engine_log(stdout, Arc::clone(&log_sink));
            }
            if let Some(stderr) = child.stderr.take() {
                pump_engine_log(stderr, Arc::clone(&log_sink));
            }

            let mut unpublished = Some(child);
            {
                let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
                if inner.generation == generation {
                    inner.child = unpublished.take();
                }
            }
            if let Some(mut child) = unpublished {
                // A stop (or the next start) claimed the generation while this
                // process was spawning. It must not become an orphan.
                terminate_engine_async(&mut child).await;
                forget_engine_pid();
                return Err(Self::superseded_message());
            }

            // Health check loop: wait up to 30 seconds for llama-server to be
            // ready on this attempt's port.
            let health_url = format!("http://127.0.0.1:{port}/health");
            let mut ready = false;
            for _ in 0..60 {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(500)) => {}
                    _ = wait_for_lifecycle_change(&mut cancelled, generation) => {
                        self.discard_child().await;
                        return Err(Self::superseded_message());
                    }
                }
                if !self.is_current_generation(generation) {
                    self.discard_child().await;
                    return Err(Self::superseded_message());
                }

                // Verify the process did not exit before it answered.
                let exited = {
                    let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
                    if inner.generation != generation {
                        return Err(Self::superseded_message());
                    }
                    if let Some(ref mut child) = inner.child {
                        if let Ok(Some(status)) = child.try_wait() {
                            inner.child = None;
                            Some(status)
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                };
                if let Some(status) = exited {
                    let mut bind_failure = log_reports_bind_failure(&log_file_path, log_offset);
                    if !bind_failure {
                        // The engine can die before its stderr reaches the log;
                        // a port that is still unavailable is the same signal.
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        bind_failure = log_reports_bind_failure(&log_file_path, log_offset)
                            || TcpListener::bind(("127.0.0.1", port)).is_err();
                    }
                    if bind_failure && port_attempts > 1 {
                        port_attempts -= 1;
                        forget_engine_pid();
                        let next = match Self::find_available_port(port.saturating_add(1)) {
                            Ok(next) => next,
                            Err(error) => {
                                return Err(self
                                    .fail_launch_error(generation, &model.id, error)
                                    .await);
                            }
                        };
                        eprintln!(
                            "local ai: port {port} was taken before llama-server bound ({status}); retrying on {next}"
                        );
                        port = next;
                        continue 'attempt;
                    }
                    let err = if bind_failure {
                        format!(
                            "llama-server could not bind 127.0.0.1:{port} after {ENGINE_PORT_ATTEMPTS} attempts: {status}"
                        )
                    } else {
                        format!("llama-server exited prematurely with status {status}")
                    };
                    return Err(self.fail_launch_error(generation, &model.id, err).await);
                }

                let resp = tokio::select! {
                    _ = wait_for_lifecycle_change(&mut cancelled, generation) => {
                        self.discard_child().await;
                        return Err(Self::superseded_message());
                    }
                    resp = client
                        .get(&health_url)
                        .header("Authorization", format!("Bearer {}", token))
                        .send() => resp,
                };
                if !self.is_current_generation(generation) {
                    self.discard_child().await;
                    return Err(Self::superseded_message());
                }

                if let Ok(response) = resp {
                    if response.status().is_success() {
                        ready = true;
                        break;
                    }
                }
            }

            if !ready {
                let err = "llama-server healthcheck timed out after 30 seconds".to_string();
                return Err(self.fail_launch_error(generation, &model.id, err).await);
            }
            break port;
        };

        // Health only proves the HTTP router is up. The model must be loaded
        // into the router before the runtime is Running and the gateway may
        // advertise it.
        if let Err(error) = self
            .load_model_into_router(generation, &mut cancelled, &client, port, &token, &model.id)
            .await
        {
            if error == Self::superseded_message() {
                self.discard_child().await;
            } else {
                self.fail_launch(generation, &model.id, &error).await;
            }
            return Err(error);
        }

        match self.publish_ready(generation, port, &model) {
            Ok(true) => Ok(()),
            Ok(false) => {
                self.discard_child().await;
                Err(Self::superseded_message())
            }
            Err(message) => {
                self.fail_launch(generation, &model.id, &message).await;
                Err(message)
            }
        }
    }

    /// Publishes `Ready` and the lifecycle revision under one lock.
    ///
    /// The publish must not hold the `RuntimeInner` guard across an `await`:
    /// the guard is not `Send`, and a lock held across the store write would
    /// also block the supervisor. Everything here is synchronous, and the
    /// caller reaps the engine outside the lock when the generation moved on
    /// while the model was loading.
    ///
    /// Returns `Ok(false)` when a newer generation superseded this launch and
    /// the caller must discard the child instead of publishing it.
    fn publish_ready(
        &self,
        generation: u64,
        port: u16,
        model: &LocalModel,
    ) -> Result<bool, String> {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            return Ok(false);
        }
        // The registry write and the lifecycle revision stay under the same
        // lock. Otherwise the supervisor can observe Running, write a
        // catalogue with no Ready model, and mark that revision synced before
        // Ready is saved. A failed write must abort the launch: without the
        // Ready row the gateway can never advertise this model.
        if let Err(error) =
            LocalModelStore::update_model_status(&model.id, ModelRuntimeStatus::Ready)
        {
            return Err(format!(
                "The model runtime status could not be saved: {error}"
            ));
        }
        inner.applied_settings = Some(model.user_settings.clone());
        inner.transition(LocalRuntimeState::Running {
            port,
            model_id: model.id.clone(),
        });
        Ok(true)
    }

    /// Re-reads `GET /models` while the router is Running and normalizes the
    /// registry to what actually has weights resident. Idle unloads turn a
    /// stale `Ready` into `Installed`, so the gateway stops advertising a
    /// route that would have to reload (or fail) on first use.
    pub async fn reconcile_router_state(&self) {
        let (generation, port, token) = {
            let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            match &inner.state {
                LocalRuntimeState::Running { port, .. } => {
                    (inner.generation, *port, inner.token.clone())
                }
                _ => return,
            }
        };

        // A rejected key stays rejected: the supervisor calls this every five
        // seconds and the engine bans a caller after five 401s, so probing again
        // would lock the app out instead of reporting the problem.
        if self.router_key_rejected.load(Ordering::Acquire) != 0 {
            return;
        }

        let states = match fetch_router_models(router_client(), port, &token).await {
            Ok(states) => states,
            Err(RouterFetchError::Unauthorized(status)) => {
                self.router_key_rejected.store(status, Ordering::Release);
                eprintln!(
                    "local ai: the engine rejected the internal key (HTTP {status}); \
                     status polling is paused until the next start/stop"
                );
                return;
            }
            Err(_) => return,
        };
        self.apply_router_snapshot(generation, port, &states);
    }

    fn apply_router_snapshot(
        &self,
        generation: u64,
        port: u16,
        states: &std::collections::HashMap<String, RouterModelState>,
    ) {
        if !self.is_current_generation(generation) {
            return;
        }

        let changes: Vec<(String, ModelRuntimeStatus)> = LocalModelStore::load_registry()
            .into_iter()
            .filter_map(|model| {
                let desired = reconciled_registry_status(
                    states.get(&model.id).copied(),
                    model.runtime_status,
                );
                (desired != model.runtime_status).then_some((model.id, desired))
            })
            .collect();
        if changes.is_empty() {
            return;
        }

        // A start/stop owns the engine while this snapshot is applied. Write
        // every change under the same lock as that check, so a stale snapshot
        // cannot overwrite the new lifecycle's registry state.
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            return;
        }
        if !matches!(&inner.state, LocalRuntimeState::Running { port: current, .. } if *current == port)
        {
            return;
        }
        for (model_id, status) in changes {
            if let Err(error) = LocalModelStore::update_model_status(&model_id, status) {
                eprintln!("local ai: could not reconcile the status of {model_id}: {error}");
            }
        }
        // Idle unload and router-side failures do not change Running, but they
        // do change the public catalogue and must dirty the gateway snapshot.
        inner.revision = inner.revision.wrapping_add(1);
    }
}

#[cfg(test)]
mod runtime_tests {
    use super::{
        apply_live_rates, extract_runtime_zip, fetch_router_models, find_llama_server,
        is_safe_component, metrics_url, normalize_sha256, package_id_for, parse_metrics,
        parse_metrics_for, parse_router_models, post_router_model_load, read_log_tail,
        read_log_tail_after, reconciled_registry_status, rotate_log_file, router_error_message,
        safe_entry_path, status_payload, validate_install_url, validate_pe_x64,
        wait_for_lifecycle_change, EngineLogSink, LocalModel, LocalModelSettings,
        LocalRuntimeManager, LocalRuntimeState, ModelRuntimeStatus, RouterModelState, RuntimeInner,
        RuntimeMetrics, StatusSnapshot,
    };
    use std::fs;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::Ordering;
    use std::sync::Arc;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn demo_model(id: &str) -> LocalModel {
        LocalModel {
            id: id.to_string(),
            schema_version: None,
            display_name: format!("{} display", id),
            provider: "Local AI".to_string(),
            source: "huggingface".to_string(),
            repo_id: None,
            revision: None,
            files: vec![format!("{}.gguf", id)],
            file_size: 4_000_000_000,
            quantization: "Q4_K_M".to_string(),
            format: "GGUF".to_string(),
            context_length: 32768,
            configured_context: 8192,
            backend: crate::local_ai::InferenceBackend::Cpu,
            gpu_offload: None,
            threads: None,
            runtime_status: ModelRuntimeStatus::Ready,
            capabilities: Vec::new(),
            installed_at: "2026-01-01T00:00:00Z".to_string(),
            updated_at: "2026-01-01T00:00:00Z".to_string(),
            last_used_at: None,
            license: None,
            checksum: None,
            architecture: None,
            user_settings: Default::default(),
        }
    }

    /// W1 regression: `get_status` used to hold `inner` and call
    /// `binary_path()`, which locks the same `std::sync::Mutex` and therefore
    /// hung forever. The worker thread plus `recv_timeout` makes the failure a
    /// test error instead of a stuck suite.
    #[test]
    fn get_status_returns_without_reentering_the_lock() {
        let manager = LocalRuntimeManager::for_test();
        let (tx, rx) = std::sync::mpsc::channel();

        std::thread::spawn(move || {
            let status = manager.get_status();
            let _ = tx.send(status);
        });

        let status = rx
            .recv_timeout(Duration::from_secs(5))
            .expect("get_status deadlocked on the runtime mutex");
        assert!(!status.is_running);
        assert!(matches!(status.state, LocalRuntimeState::Stopped));
        assert_eq!(status.current_model, None);
    }

    /// A superseded start must not publish its terminal state over the
    /// generation that replaced it.
    #[test]
    fn superseded_generation_cannot_publish_failed() {
        let manager = LocalRuntimeManager::for_test();
        let (first, _) = manager.begin_lifecycle();
        assert!(manager.transition_if_current(
            first,
            LocalRuntimeState::Running {
                port: 18318,
                model_id: "local/first".to_string(),
            },
        ));
        let (second, _) = manager.begin_lifecycle();
        assert!(second > first);

        assert!(!manager.transition_if_current(
            first,
            LocalRuntimeState::Failed {
                error: "old launch timed out".to_string(),
            },
        ));
        assert!(manager.transition_if_current(
            second,
            LocalRuntimeState::Failed {
                error: "new launch failed".to_string(),
            },
        ));

        let inner = manager.inner.lock().unwrap();
        match &inner.state {
            LocalRuntimeState::Failed { error } => assert_eq!(error, "new launch failed"),
            other => panic!("unexpected state {other:?}"),
        }
    }

    /// `load_model` publishes `Starting` before writing `models.ini` and
    /// opening the engine log. A failure there must become a terminal state,
    /// otherwise the renderer spins forever on a launch that never reports.
    #[tokio::test(flavor = "current_thread")]
    async fn a_failed_launch_step_publishes_failed_instead_of_staying_starting() {
        let manager = LocalRuntimeManager::for_test();
        let (generation, _) = manager.begin_lifecycle();
        let model_id = "local/preset-failure-test";
        {
            let mut inner = manager.inner.lock().unwrap();
            inner.current_model = Some(demo_model(model_id));
            inner.transition(LocalRuntimeState::Starting {
                model_id: model_id.to_string(),
            });
        }

        assert!(
            manager
                .fail_launch(generation, model_id, "No installed model files to serve.")
                .await
        );

        let status = manager.get_status();
        match status.state {
            LocalRuntimeState::Failed { error } => {
                assert_eq!(error, "No installed model files to serve.")
            }
            other => panic!("unexpected state {other:?}"),
        }
        assert!(!status.is_running);
        assert!(!status.is_starting);
        assert_eq!(status.failed_model_id.as_deref(), Some(model_id));
        assert!(status.applied_settings.is_none());
    }

    /// Stop during a launch has to wake the launch's health wait and then
    /// finish `Stopped`; it must not leave a late health timeout to publish
    /// `Failed` afterwards.
    #[tokio::test(flavor = "current_thread")]
    async fn stop_during_start_cancels_the_launch_and_leaves_stopped() {
        let manager = Arc::new(LocalRuntimeManager::for_test());
        let (generation, mut cancelled) = manager.begin_lifecycle();
        let guard = manager.lifecycle.lock().await;
        assert!(manager.is_current_generation(generation));

        let stopping = Arc::clone(&manager);
        let stop = tokio::spawn(async move { stopping.stop().await });

        tokio::time::timeout(Duration::from_secs(2), async {
            while manager.is_current_generation(generation) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("stop did not supersede the in-flight launch");

        tokio::time::timeout(
            Duration::from_secs(1),
            wait_for_lifecycle_change(&mut cancelled, generation),
        )
        .await
        .expect("the launch was not woken by the stop");

        drop(guard);
        stop.await.unwrap();

        let inner = manager.inner.lock().unwrap();
        assert!(matches!(inner.state, LocalRuntimeState::Stopped));
        assert!(inner.child.is_none());
    }

    /// A stop that lost the race to a newer start must return without killing
    /// or publishing over that newer process.
    #[tokio::test(flavor = "current_thread")]
    async fn a_stale_stop_does_not_publish_stopped_over_a_newer_start() {
        let manager = Arc::new(LocalRuntimeManager::for_test());
        let (running, _) = manager.begin_lifecycle();
        assert!(manager.transition_if_current(
            running,
            LocalRuntimeState::Running {
                port: 18318,
                model_id: "local/new".to_string(),
            },
        ));
        // Hold the lifecycle lock as if that newer start were still running.
        let guard = manager.lifecycle.lock().await;

        let stopping = Arc::clone(&manager);
        let stop = tokio::spawn(async move { stopping.stop().await });
        tokio::time::timeout(Duration::from_secs(2), async {
            while manager.is_current_generation(running) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("stop did not claim a generation");

        // Another start supersedes the queued stop before it gets the lock.
        let (newest, _) = manager.begin_lifecycle();
        assert!(manager.is_current_generation(newest));

        drop(guard);
        stop.await.unwrap();

        let inner = manager.inner.lock().unwrap();
        assert!(matches!(inner.state, LocalRuntimeState::Running { .. }));
    }

    /// Two overlapping starts are serialized by `lifecycle`; only the newest
    /// generation may publish, and the canceled one cannot append `Failed`.
    #[tokio::test(flavor = "current_thread")]
    async fn concurrent_starts_publish_only_the_newest_generation() {
        let manager = Arc::new(LocalRuntimeManager::for_test());
        let (first, mut first_cancelled) = manager.begin_lifecycle();
        let guard = manager.lifecycle.lock().await;

        let starting = Arc::clone(&manager);
        let second = tokio::spawn(async move {
            let (generation, _) = starting.begin_lifecycle();
            let _guard = starting.lifecycle.lock().await;
            assert!(starting.is_current_generation(generation));
            starting.transition_if_current(
                generation,
                LocalRuntimeState::Running {
                    port: 18319,
                    model_id: "local/second".to_string(),
                },
            )
        });

        tokio::time::timeout(Duration::from_secs(2), async {
            while manager.is_current_generation(first) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("the second start did not claim a generation");
        tokio::time::timeout(
            Duration::from_secs(1),
            wait_for_lifecycle_change(&mut first_cancelled, first),
        )
        .await
        .expect("the first launch was not woken by the second start");

        drop(guard);
        assert!(second.await.unwrap());
        // The canceled first launch cannot overwrite the winner with `Failed`.
        assert!(!manager.transition_if_current(
            first,
            LocalRuntimeState::Failed {
                error: "old launch timed out".to_string(),
            },
        ));

        let inner = manager.inner.lock().unwrap();
        match &inner.state {
            LocalRuntimeState::Running { model_id, .. } => assert_eq!(model_id, "local/second"),
            other => panic!("unexpected state {other:?}"),
        }
    }

    #[test]
    fn router_snapshot_parses_pinned_b12099_model_states() {
        let body = r#"{"object":"list","data":[
            {"id":"local/loaded","status":{"value":"loaded"},"meta":{"n_ctx":8192}},
            {"id":"local/loading","status":{"value":"loading"}},
            {"id":"local/unloaded","status":{"value":"unloaded"}},
            {"id":"local/sleeping","status":{"value":"sleeping"}},
            {"id":"local/failed","status":{"value":"failed"}},
            {"id":"local/unknown","status":{"value":"mystery"}},
            {"id":"local/no-status"}
        ]}"#;
        let states = parse_router_models(body).expect("pinned router shape must parse");
        assert_eq!(states.get("local/loaded"), Some(&RouterModelState::Loaded));
        assert_eq!(
            states.get("local/loading"),
            Some(&RouterModelState::Loading)
        );
        assert_eq!(
            states.get("local/unloaded"),
            Some(&RouterModelState::Unloaded)
        );
        assert_eq!(
            states.get("local/sleeping"),
            Some(&RouterModelState::Sleeping)
        );
        assert_eq!(states.get("local/failed"), Some(&RouterModelState::Failed));
        assert_eq!(
            states.get("local/unknown"),
            Some(&RouterModelState::Unknown)
        );
        assert_eq!(
            states.get("local/no-status"),
            Some(&RouterModelState::Unloaded)
        );
        assert_eq!(parse_router_models(r#"{"data":[]}"#).unwrap().len(), 0);
        assert!(parse_router_models("not json").is_none());
        assert!(parse_router_models(r#"{"object":"list"}"#).is_none());
    }

    #[test]
    fn router_reconcile_drops_stale_ready_after_idle_unload() {
        assert_eq!(
            reconciled_registry_status(
                Some(RouterModelState::Loaded),
                ModelRuntimeStatus::Installed
            ),
            ModelRuntimeStatus::Ready
        );
        for state in [
            RouterModelState::Unloaded,
            RouterModelState::Sleeping,
            RouterModelState::Unknown,
        ] {
            assert_eq!(
                reconciled_registry_status(Some(state), ModelRuntimeStatus::Ready),
                ModelRuntimeStatus::Installed,
                "{state:?} must stop advertising a Ready route"
            );
        }
        assert_eq!(
            reconciled_registry_status(Some(RouterModelState::Loading), ModelRuntimeStatus::Ready),
            ModelRuntimeStatus::Loading
        );
        assert_eq!(
            reconciled_registry_status(Some(RouterModelState::Failed), ModelRuntimeStatus::Ready),
            ModelRuntimeStatus::Error
        );
        // Absent from the live router is not warm either.
        assert_eq!(
            reconciled_registry_status(None, ModelRuntimeStatus::Ready),
            ModelRuntimeStatus::Installed
        );
        assert_eq!(
            reconciled_registry_status(None, ModelRuntimeStatus::Error),
            ModelRuntimeStatus::Error
        );
    }

    #[test]
    fn router_error_message_prefers_json_and_falls_back_to_status() {
        assert_eq!(
            router_error_message(r#"{"error":{"message":"CUDA out of memory"}}"#, 500),
            "HTTP 500: CUDA out of memory"
        );
        assert_eq!(
            router_error_message(r#"{"message":"bad preset"}"#, 400),
            "HTTP 400: bad preset"
        );
        assert_eq!(
            router_error_message("  plain body \n", 502),
            "HTTP 502: plain body"
        );
        assert_eq!(router_error_message("", 503), "HTTP 503");
        // The status survives a rejected key, which is what tells it apart
        // from a slow load.
        assert_eq!(
            router_error_message("unauthorized", 401),
            "HTTP 401: unauthorized"
        );
        assert_eq!(
            router_error_message(r#"{"error":{"message":"  "}}"#, 403),
            "HTTP 403"
        );
    }

    /// Minimal one-shot HTTP fixture: records the request, then answers with
    /// the recorded status/body through the real reqwest client.
    fn spawn_router_fixture(
        status: &'static str,
        body: &'static str,
    ) -> (u16, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).expect("bind router fixture");
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept router request");
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            let mut chunk = [0u8; 1024];
            while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                match stream.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => request.extend_from_slice(&chunk[..read]),
                }
            }
            let response = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
            let _ = stream.flush();
        });
        (port, handle)
    }

    #[tokio::test(flavor = "current_thread")]
    async fn router_load_post_accepts_2xx() {
        let (port, server) = spawn_router_fixture("200 OK", "{}");
        let client = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap_or_default();
        post_router_model_load(&client, port, "token", "local/qwen")
            .await
            .expect("2xx must be accepted");
        server.join().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn router_load_post_preserves_engine_rejection_message() {
        let (port, server) = spawn_router_fixture(
            "500 Internal Server Error",
            r#"{"error":{"message":"model does not fit"}}"#,
        );
        let client = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap_or_default();
        let error = post_router_model_load(&client, port, "token", "local/qwen")
            .await
            .expect_err("HTTP 500 must fail");
        assert!(error.contains("local/qwen"), "{error}");
        assert!(error.contains("model does not fit"), "{error}");
        server.join().unwrap();
    }

    #[tokio::test(flavor = "current_thread")]
    async fn router_snapshot_fixture_reads_loaded_state() {
        let (port, server) = spawn_router_fixture(
            "200 OK",
            r#"{"data":[{"id":"local/qwen","status":{"value":"loaded"}}]}"#,
        );
        let client = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap_or_default();
        let states = fetch_router_models(&client, port, "token")
            .await
            .expect("fixture must parse");
        assert_eq!(states.get("local/qwen"), Some(&RouterModelState::Loaded));
        server.join().unwrap();
    }

    #[test]
    fn status_payload_reports_the_current_model_for_every_state() {
        let mut inner = RuntimeInner {
            child: None,
            current_model: Some(demo_model("local/qwen")),
            port: 18318,
            token: "token".to_string(),
            state: LocalRuntimeState::Running {
                port: 18318,
                model_id: "local/qwen".to_string(),
            },
            custom_binary_path: None,
            revision: 3,
            state_changed_at: std::time::Instant::now(),
            last_metrics: None,
            logs_cleared_at: 0,
            applied_settings: None,
            generation: 0,
        };

        inner.applied_settings = Some(LocalModelSettings {
            context_length: 4096,
            ..LocalModelSettings::default()
        });
        let running = status_payload(StatusSnapshot::capture(&inner), None, None);
        assert!(running.is_running);
        // The launch snapshot is what the UI compares stored settings with.
        assert_eq!(
            running
                .applied_settings
                .as_ref()
                .map(|settings| settings.context_length),
            Some(4096)
        );
        assert_eq!(
            running
                .current_model
                .as_ref()
                .map(|model| model.id.as_str()),
            Some("local/qwen")
        );
        // The compatibility alias still carries the same id.
        assert_eq!(running.model_id.as_deref(), Some("local/qwen"));
        assert_eq!(running.revision, 3);

        inner.transition(LocalRuntimeState::Starting {
            model_id: "local/qwen".to_string(),
        });
        let starting = status_payload(StatusSnapshot::capture(&inner), None, None);
        assert!(starting.is_starting && !starting.is_running);
        assert_eq!(starting.starting_model_id.as_deref(), Some("local/qwen"));
        assert_eq!(
            starting
                .current_model
                .as_ref()
                .map(|model| model.id.as_str()),
            Some("local/qwen")
        );

        inner.transition(LocalRuntimeState::Failed {
            error: "boom".to_string(),
        });
        let failed = status_payload(StatusSnapshot::capture(&inner), None, None);
        assert_eq!(failed.error.as_deref(), Some("boom"));
        assert_eq!(failed.failed_model_id.as_deref(), Some("local/qwen"));
        assert!(!failed.is_running && !failed.is_starting);
    }

    #[test]
    fn a_lost_engine_reload_is_retried_instead_of_marked_as_published() {
        let manager = LocalRuntimeManager::for_test();
        manager.inner.lock().unwrap().revision = 1;
        manager.mark_gateway_synced(1);
        assert_eq!(manager.pending_gateway_revision(), None);
        assert!(manager.publication_reporter().is_current(1));
        assert!(!manager.publication_reporter().is_current(0));

        // The engine answered HTTP before its config watcher was armed, so the
        // catalogue poll timed out and asked for another write.
        manager.publication_reporter().request_resync(1);
        assert_eq!(manager.pending_gateway_revision(), Some(1));

        // A newer transition already published must not be rewritten by a
        // late poll from the previous revision.
        manager.inner.lock().unwrap().revision = 2;
        manager.mark_gateway_synced(2);
        manager.publication_reporter().request_resync(1);
        assert_eq!(manager.pending_gateway_revision(), None);
    }

    #[test]
    fn a_late_publication_result_cannot_overwrite_a_newer_one() {
        let manager = LocalRuntimeManager::for_test();
        let reporter = manager.publication_reporter();
        manager.inner.lock().unwrap().revision = 6;
        reporter.report(4, Some("stale".to_string()));
        assert_eq!(manager.current_publication_error(), None);
        reporter.report(6, Some("new".to_string()));
        assert_eq!(manager.current_publication_error().as_deref(), Some("new"));

        // A relay that never bound its port is reported next to the catalogue
        // error and survives a successful publication, which clears `message`.
        reporter.report_prompt_relay_error(Some("could not bind 127.0.0.1:0".to_string()));
        reporter.report(6, None);
        assert_eq!(
            manager.current_publication_error().as_deref(),
            Some("Prompt relay did not start: could not bind 127.0.0.1:0")
        );
        reporter.report_prompt_relay_error(None);
        assert_eq!(manager.current_publication_error(), None);
    }

    /// A 401 from the router is a standing condition, not a publication
    /// result: it must keep showing after a later catalogue write succeeds,
    /// otherwise the user only sees a launch that never finishes.
    #[test]
    fn a_rejected_internal_key_stays_reported_after_publication() {
        let manager = LocalRuntimeManager::for_test();
        manager.router_key_rejected.store(401, Ordering::Release);
        manager.publication.report(manager.revision(), None);
        assert_eq!(
            manager.current_publication_error().as_deref(),
            Some("The local engine rejected the internal key (HTTP 401). Restart the engine from the Runtime tab.")
        );
        // A new lifecycle clears the latch, and the stale revision with it.
        manager.begin_lifecycle();
        assert_eq!(manager.current_publication_error(), None);
    }

    #[test]
    fn a_running_state_without_a_process_is_normalized_to_failed() {
        let mut inner = RuntimeInner {
            child: None,
            current_model: Some(demo_model("local/ghost")),
            port: 18318,
            token: "token".to_string(),
            state: LocalRuntimeState::Running {
                port: 18318,
                model_id: "local/ghost".to_string(),
            },
            custom_binary_path: None,
            revision: 0,
            // Past the launch grace period: `Starting` briefly has no child.
            state_changed_at: std::time::Instant::now() - Duration::from_secs(30),
            last_metrics: None,
            logs_cleared_at: 0,
            applied_settings: None,
            generation: 0,
        };

        let update = inner.settle();
        assert_eq!(
            update,
            Some(("local/ghost".to_string(), ModelRuntimeStatus::Error))
        );
        assert!(matches!(inner.state, LocalRuntimeState::Failed { .. }));
        // Kept so `failedModelId` still points at the model's card.
        assert!(inner.current_model.is_some());
    }

    #[test]
    fn a_freshly_started_launch_is_not_failed_before_the_process_exists() {
        let mut inner = RuntimeInner {
            child: None,
            current_model: Some(demo_model("local/booting")),
            port: 18318,
            token: "token".to_string(),
            state: LocalRuntimeState::Starting {
                model_id: "local/booting".to_string(),
            },
            custom_binary_path: None,
            revision: 0,
            state_changed_at: std::time::Instant::now(),
            last_metrics: None,
            logs_cleared_at: 0,
            applied_settings: None,
            generation: 0,
        };

        assert_eq!(inner.settle(), None);
        assert!(matches!(inner.state, LocalRuntimeState::Starting { .. }));
    }

    #[test]
    fn router_unload_and_reload_republish_catalogue_without_lifecycle_transition() {
        use crate::local_ai::local_models::{with_test_root, LocalModelStore};
        let root =
            std::env::temp_dir().join(format!("melon-runtime-catalogue-{}", uuid::Uuid::new_v4()));
        with_test_root(&root, || {
            let model = demo_model("local/qwen");
            LocalModelStore::save_registry(&[model]).unwrap();
            let manager = LocalRuntimeManager::for_test();
            let (generation, _) = manager.begin_lifecycle();
            manager
                .inner
                .lock()
                .unwrap()
                .transition(LocalRuntimeState::Running {
                    port: 18318,
                    model_id: "local/qwen".to_string(),
                });
            manager.mark_gateway_synced(manager.pending_gateway_revision().unwrap());
            let mut states = std::collections::HashMap::new();
            states.insert("local/qwen".to_string(), RouterModelState::Unloaded);
            manager.apply_router_snapshot(generation, 18318, &states);
            assert!(crate::gateway::servable_local_models().is_empty());
            let unloaded = manager
                .pending_gateway_revision()
                .expect("unload must dirty catalogue");
            manager.mark_gateway_synced(unloaded);
            manager.apply_router_snapshot(generation, 18318, &states);
            assert_eq!(
                manager.pending_gateway_revision(),
                None,
                "unchanged poll must not rewrite config"
            );
            states.insert("local/qwen".to_string(), RouterModelState::Loaded);
            manager.apply_router_snapshot(generation, 18318, &states);
            assert_eq!(crate::gateway::servable_local_models().len(), 1);
            assert!(manager.pending_gateway_revision().is_some());
            manager.apply_router_snapshot(generation.wrapping_sub(1), 18318, &Default::default());
            assert_eq!(
                crate::gateway::servable_local_models().len(),
                1,
                "stale snapshot cannot remove new route"
            );
        });
        std::fs::remove_dir_all(root).unwrap();
    }

    /// REVIEW gap: a crash/restart leaves whatever status the last session
    /// wrote. A stale `Ready` row must not reach the first gateway config —
    /// `normalize_stale_statuses` clears it before the supervisor builds one,
    /// and the manager starts with a dirty revision so that rewrite happens.
    #[test]
    fn stale_ready_status_is_normalized_before_the_first_gateway_config() {
        use crate::local_ai::local_models::{with_test_root, LocalModelStore};
        let root =
            std::env::temp_dir().join(format!("melon-runtime-stale-{}", uuid::Uuid::new_v4()));
        with_test_root(&root, || {
            LocalModelStore::save_registry(&[demo_model("local/stale")]).unwrap();
            assert_eq!(crate::gateway::servable_local_models().len(), 1);

            RuntimeInner::normalize_stale_statuses();
            assert_eq!(
                LocalModelStore::load_registry()[0].runtime_status,
                ModelRuntimeStatus::Installed
            );
            assert!(crate::gateway::servable_local_models().is_empty());

            let manager = LocalRuntimeManager::for_test();
            manager.set_revision_for_test(1);
            assert_eq!(
                manager.pending_gateway_revision(),
                Some(1),
                "a fresh manager must republish instead of trusting the old config"
            );
            let yaml = crate::gateway::api_keys_yaml_with_local(
                &crate::settings::Settings::default(),
                &[],
                0,
                "",
            );
            assert!(!yaml.contains("local/stale"), "{yaml}");
            assert!(!yaml.contains("melon-local-ai"), "{yaml}");
        });
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn router_preset_enables_structured_tool_call_templates() {
        use crate::local_ai::local_models::{with_test_root, LocalModelStore};
        let root =
            std::env::temp_dir().join(format!("melon-runtime-tools-{}", uuid::Uuid::new_v4()));
        with_test_root(&root, || {
            let mut model = demo_model("local/qwen");
            model.files = vec!["weights.gguf".to_string()];
            let models_dir = LocalModelStore::models_dir();
            std::fs::create_dir_all(&models_dir).unwrap();
            std::fs::write(models_dir.join("weights.gguf"), b"stub").unwrap();
            LocalModelStore::save_registry(&[model]).unwrap();
            let preset = LocalRuntimeManager::write_models_preset(
                &models_dir,
                crate::local_ai::InferenceBackend::Cpu,
                4,
            )
            .unwrap();
            let ini = std::fs::read_to_string(preset).unwrap();
            assert!(ini.contains("alias = local/qwen\njinja = true\n"));
        });
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn every_transition_marks_the_gateway_catalogue_dirty() {
        let manager = LocalRuntimeManager::for_test();
        assert_eq!(manager.pending_gateway_revision(), None);

        {
            let mut inner = manager.inner.lock().unwrap();
            inner.transition(LocalRuntimeState::Starting {
                model_id: "local/a".to_string(),
            });
        }
        let dirty = manager.pending_gateway_revision().expect("dirty");
        manager.mark_gateway_synced(dirty);
        assert_eq!(manager.pending_gateway_revision(), None);

        {
            let mut inner = manager.inner.lock().unwrap();
            inner.transition(LocalRuntimeState::Failed {
                error: "crash".to_string(),
            });
        }
        assert!(manager.pending_gateway_revision().is_some());
    }

    const ACTUAL: &str = "\
# HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.
# TYPE llamacpp:prompt_tokens_total counter
llamacpp:prompt_tokens_total 128
llamacpp:tokens_predicted_total 64
llamacpp:prompt_tokens_seconds 12.5
llamacpp:predicted_tokens_seconds 42.5
llamacpp:requests_processing 1
llamacpp:requests_deferred 2
llamacpp:tokens_predicted_seconds_total 3.25
process_cpu_seconds_total 1.5
";

    #[test]
    fn parses_actual_llama_cpp_counters_and_gauges() {
        let metrics = parse_metrics(ACTUAL);

        assert_eq!(metrics.prompt_tokens_total, Some(128));
        assert_eq!(metrics.generated_tokens_total, Some(64));
        assert_eq!(metrics.prompt_tokens_per_second, Some(12.5));
        assert_eq!(metrics.generated_tokens_per_second, Some(42.5));
        assert_eq!(metrics.requests_processing, Some(1));
        assert_eq!(metrics.requests_deferred, Some(2));
    }

    #[test]
    fn elapsed_seconds_counters_are_not_mistaken_for_rates() {
        let metrics = parse_metrics(
            "llamacpp:tokens_predicted_seconds_total 100\n\
             llamacpp:prompt_seconds_total 50\n",
        );
        assert_eq!(metrics.generated_tokens_per_second, None);
        assert_eq!(metrics.prompt_tokens_per_second, None);
    }

    #[test]
    fn zero_gauges_fall_back_to_counter_averages() {
        let body = "\
llamacpp:prompt_tokens_total 1000
llamacpp:tokens_predicted_total 200
llamacpp:prompt_seconds_total 10
llamacpp:tokens_predicted_seconds_total 20
llamacpp:prompt_tokens_seconds 0
llamacpp:predicted_tokens_seconds 0
";
        let metrics = parse_metrics(body);
        assert_eq!(metrics.prompt_tokens_per_second, Some(100.0));
        assert_eq!(metrics.generated_tokens_per_second, Some(10.0));
    }

    #[test]
    fn tiny_elapsed_does_not_invent_a_rate() {
        // 2 tokens over 0.000002 s used to surface as 1_000_000.0 tok/s.
        let body = "\
llamacpp:prompt_tokens_total 2
llamacpp:tokens_predicted_total 2
llamacpp:prompt_seconds_total 0.000002
llamacpp:tokens_predicted_seconds_total 0.000002
llamacpp:prompt_tokens_seconds 0
llamacpp:predicted_tokens_seconds 0
";
        let metrics = parse_metrics(body);
        assert_eq!(metrics.prompt_tokens_per_second, None);
        assert_eq!(metrics.generated_tokens_per_second, None);
    }

    #[test]
    fn live_rates_come_from_counter_deltas() {
        let previous = RuntimeMetrics {
            generated_tokens_total: Some(100),
            prompt_tokens_total: Some(50),
            ..RuntimeMetrics::default()
        };
        let mut current = RuntimeMetrics {
            generated_tokens_total: Some(140),
            prompt_tokens_total: Some(50),
            ..RuntimeMetrics::default()
        };
        apply_live_rates(&mut current, &previous, 2.0);
        assert_eq!(current.generated_tokens_per_second, Some(20.0));
        // The prompt counter did not move: keep whatever the exposition said.
        assert_eq!(current.prompt_tokens_per_second, None);
    }

    #[test]
    fn live_rates_survive_a_counter_reset() {
        let previous = RuntimeMetrics {
            generated_tokens_total: Some(500),
            ..RuntimeMetrics::default()
        };
        let mut current = RuntimeMetrics {
            generated_tokens_total: Some(5),
            generated_tokens_per_second: Some(12.5),
            ..RuntimeMetrics::default()
        };
        apply_live_rates(&mut current, &previous, 2.0);
        assert_eq!(current.generated_tokens_per_second, Some(12.5));
    }

    #[test]
    fn absurd_delta_keeps_the_previous_rate() {
        let previous = RuntimeMetrics {
            generated_tokens_total: Some(0),
            generated_tokens_per_second: Some(21.5),
            ..RuntimeMetrics::default()
        };
        let mut current = RuntimeMetrics {
            generated_tokens_total: Some(5_000_000),
            ..RuntimeMetrics::default()
        };
        apply_live_rates(&mut current, &previous, 1.0);
        assert_eq!(current.generated_tokens_per_second, Some(21.5));
    }

    fn temp_log_path(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "melon-{}-{}-{}.log",
            tag,
            std::process::id(),
            nanos
        ))
    }

    #[test]
    fn engine_log_rotation_caps_the_file_and_keeps_a_bounded_set() {
        let path = temp_log_path("rotate");
        fs::write(&path, b"first generation").unwrap();

        assert!(!rotate_log_file(&path, 1024, 2).unwrap(), "under the cap");
        assert!(path.exists());

        // Over the cap: the live file becomes `.1`.
        fs::write(&path, b"second generation").unwrap();
        assert!(rotate_log_file(&path, 4, 2).unwrap());
        assert!(!path.exists());
        assert_eq!(
            fs::read(path.with_extension("log.1")).unwrap(),
            b"second generation"
        );

        // A second rotation shifts `.1` to `.2` and drops anything older.
        fs::write(&path, b"third generation").unwrap();
        assert!(rotate_log_file(&path, 4, 2).unwrap());
        assert_eq!(
            fs::read(path.with_extension("log.1")).unwrap(),
            b"third generation"
        );
        assert_eq!(
            fs::read(path.with_extension("log.2")).unwrap(),
            b"second generation"
        );
        assert!(!path.with_extension("log.3").exists());

        for suffix in ["log.1", "log.2"] {
            let _ = fs::remove_file(path.with_extension(suffix));
        }
    }

    #[test]
    fn the_live_log_writer_rotates_within_one_engine_lifetime() {
        let path = temp_log_path("sink");
        let mut sink = EngineLogSink::open(&path, 10, 2).unwrap();
        sink.write_chunk(b"12345").unwrap();
        sink.write_chunk(b"6789").unwrap();
        assert!(!path.with_extension("log.1").exists());

        // 9 + 5 > 10: the writer closes, rotates and reopens by itself.
        sink.write_chunk(b"abcde").unwrap();
        assert_eq!(
            fs::read(path.with_extension("log.1")).unwrap(),
            b"123456789"
        );
        assert_eq!(fs::read(&path).unwrap(), b"abcde");

        for suffix in ["log.1", "log.2"] {
            let _ = fs::remove_file(path.with_extension(suffix));
        }
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn log_tail_returns_the_newest_lines_in_order() {
        let path = temp_log_path("tail");
        let body: String = (1..=10).map(|n| format!("line {}\n", n)).collect();
        fs::write(&path, body).unwrap();

        let tail = read_log_tail(&path, 3).unwrap();
        assert_eq!(tail, vec!["line 8", "line 9", "line 10"]);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn missing_log_is_empty_and_not_an_error() {
        let path = temp_log_path("missing");
        let _ = fs::remove_file(&path);
        assert!(read_log_tail(&path, 10).unwrap().is_empty());
    }

    #[test]
    fn reading_after_a_clear_offset_shows_only_new_lines() {
        let path = temp_log_path("clear");
        fs::write(&path, "old one\nold two\n").unwrap();
        let after = fs::metadata(&path).unwrap().len();
        fs::write(&path, "old one\nold two\nnew one\n").unwrap();

        let tail = read_log_tail_after(&path, 10, after).unwrap();
        assert_eq!(tail, vec!["new one"]);
        // Clearing records an offset; it must not truncate the engine's file.
        assert!(fs::metadata(&path).unwrap().len() > after);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_stale_clear_offset_reads_the_whole_file() {
        let path = temp_log_path("stale-clear");
        fs::write(&path, "recreated\n").unwrap();
        let tail = read_log_tail_after(&path, 10, 99_999).unwrap();
        assert_eq!(tail, vec!["recreated"]);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn log_tail_caps_absurdly_long_lines() {
        let path = temp_log_path("long");
        fs::write(&path, "x".repeat(5_000)).unwrap();
        let tail = read_log_tail(&path, 1).unwrap();
        assert_eq!(tail.len(), 1);
        assert_eq!(tail[0].chars().count(), 2_001);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn model_labels_filter_a_multi_model_exposition() {
        let body = "\
llamacpp:prompt_tokens_total{model=\"alpha\"} 10
llamacpp:tokens_predicted_total{model=\"alpha\"} 20
llamacpp:prompt_tokens_total{model=\"beta\"} 30
llamacpp:tokens_predicted_total{model=\"beta\"} 40
llamacpp:predicted_tokens_seconds{model=\"beta\"} 9.5
";

        let beta = parse_metrics_for(body, Some("beta"));
        assert_eq!(beta.prompt_tokens_total, Some(30));
        assert_eq!(beta.generated_tokens_total, Some(40));
        assert_eq!(beta.generated_tokens_per_second, Some(9.5));
        assert_eq!(beta.model_id.as_deref(), Some("beta"));

        // Unlabelled lines still count for the requested model: router mode
        // proxies a child exposition that carries no model label.
        let unlabelled = parse_metrics_for("llamacpp:prompt_tokens_total 7\n", Some("alpha"));
        assert_eq!(unlabelled.prompt_tokens_total, Some(7));
        assert_eq!(unlabelled.model_id.as_deref(), Some("alpha"));
    }

    #[test]
    fn malformed_values_do_not_poison_the_snapshot() {
        let body = "\
llamacpp:prompt_tokens_total NaN
llamacpp:tokens_predicted_total +Inf
llamacpp:prompt_tokens_seconds not-a-number
llamacpp:predicted_tokens_seconds 12.5 1700000000
llamacpp:requests_processing
";
        let metrics = parse_metrics(body);

        assert_eq!(metrics.prompt_tokens_total, None);
        assert_eq!(metrics.generated_tokens_total, None);
        assert_eq!(metrics.prompt_tokens_per_second, None);
        // A trailing Prometheus timestamp is ignored.
        assert_eq!(metrics.generated_tokens_per_second, Some(12.5));
        assert_eq!(metrics.requests_processing, None);
    }

    #[test]
    fn missing_metrics_stay_empty() {
        let metrics = parse_metrics("# empty\n\n# EOF\n");
        assert_eq!(metrics, Default::default());
    }

    #[test]
    fn router_url_names_the_model_and_keeps_it_encoded() {
        let url = metrics_url(18318, "org/model a&b");
        let parsed = url::Url::parse(&url).unwrap();
        assert_eq!(parsed.path(), "/metrics");
        assert_eq!(parsed.port(), Some(18318));
        let model = parsed
            .query_pairs()
            .find(|(key, _)| key == "model")
            .map(|(_, value)| value.into_owned());
        assert_eq!(model.as_deref(), Some("org/model a&b"));
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "melontools-runtime-{}-{}-{}",
            std::process::id(),
            tag,
            stamp
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn archive_sha256_must_be_complete_hex() {
        assert_eq!(normalize_sha256(&"A".repeat(64)).unwrap(), "a".repeat(64));
        assert!(normalize_sha256("").is_err());
        assert!(normalize_sha256(&"a".repeat(63)).is_err());
        assert!(normalize_sha256(&"g".repeat(64)).is_err());
        assert_eq!(package_id_for(&"a".repeat(64)), "a".repeat(12));
    }

    #[test]
    fn install_url_requires_https_and_no_credentials() {
        assert!(validate_install_url("https://example.com/runtime.zip").is_ok());
        assert!(validate_install_url("http://example.com/runtime.zip").is_err());
        assert!(validate_install_url("http://user:pass@example.com/runtime.zip").is_err());
        assert!(validate_install_url("https://user:pass@example.com/runtime.zip").is_err());
        assert!(validate_install_url("file:///tmp/runtime.zip").is_err());
        assert!(validate_install_url("ftp://example.com/runtime.zip").is_err());
        assert!(validate_install_url("not a url").is_err());
    }

    #[test]
    fn pe_x64_header_is_checked_without_executing() {
        let root = temp_dir("pe");

        let valid = root.join("ok.exe");
        write_pe(&valid, 0x8664, true, 0x80);
        assert!(validate_pe_x64(&valid).is_ok());

        let x86 = root.join("x86.exe");
        write_pe(&x86, 0x014c, true, 0x80);
        assert!(validate_pe_x64(&x86).unwrap_err().contains("not x64"));

        let no_signature = root.join("nosig.exe");
        write_pe(&no_signature, 0x8664, false, 0x80);
        assert!(validate_pe_x64(&no_signature)
            .unwrap_err()
            .contains("PE signature"));

        let no_mz = root.join("nomz.exe");
        fs::write(&no_mz, vec![0u8; 0x100]).unwrap();
        assert!(validate_pe_x64(&no_mz).unwrap_err().contains("MZ"));

        let tiny = root.join("tiny.exe");
        fs::write(&tiny, b"MZ").unwrap();
        assert!(validate_pe_x64(&tiny).unwrap_err().contains("too small"));

        let bad_offset = root.join("offset.exe");
        write_pe(&bad_offset, 0x8664, true, 0x7fffffff);
        assert!(validate_pe_x64(&bad_offset)
            .unwrap_err()
            .contains("invalid PE offset"));

        let _ = fs::remove_dir_all(root);
    }

    fn write_pe(path: &Path, machine: u16, signature: bool, pe_offset: u32) {
        let mut bytes = vec![0u8; 0x100];
        bytes[..2].copy_from_slice(b"MZ");
        bytes[0x3c..0x40].copy_from_slice(&pe_offset.to_le_bytes());
        let offset = pe_offset as usize;
        if signature && offset + 24 <= bytes.len() {
            bytes[offset..offset + 4].copy_from_slice(b"PE\0\0");
            bytes[offset + 4..offset + 6].copy_from_slice(&machine.to_le_bytes());
        }
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn archive_paths_must_stay_inside_staging() {
        assert_eq!(
            safe_entry_path(Path::new("dir/llama-server.exe")),
            Some(PathBuf::from("dir/llama-server.exe"))
        );
        assert_eq!(
            safe_entry_path(Path::new("./llama-server.exe")),
            Some(PathBuf::from("llama-server.exe"))
        );
        assert_eq!(safe_entry_path(Path::new("../escape.dll")), None);
        assert_eq!(safe_entry_path(Path::new("/absolute.dll")), None);
        assert_eq!(safe_entry_path(Path::new(".")), None);
    }

    #[test]
    fn windows_special_entry_names_are_rejected() {
        for bad in [
            "CON",
            "con.txt",
            "AUX",
            "nul.log",
            "COM1",
            "lpt9.dll",
            "file:stream",
            "trailing.",
            "trailing ",
            "",
        ] {
            assert!(
                !is_safe_component(std::ffi::OsStr::new(bad)),
                "{bad:?} must be rejected"
            );
        }
        for good in ["llama-server.exe", "ggml-cuda.dll", "sub dir", "COM0"] {
            assert!(
                is_safe_component(std::ffi::OsStr::new(good)),
                "{good:?} must be accepted"
            );
        }
    }

    #[test]
    fn traversal_entry_is_rejected_before_writing() {
        let root = temp_dir("zip");
        let archive = root.join("traversal.zip");
        {
            use std::io::Write;
            let file = fs::File::create(&archive).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            writer
                .start_file("../escape.txt", zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(b"owned").unwrap();
            writer.finish().unwrap();
        }
        let staging = root.join("staging");

        let error = extract_runtime_zip(&archive, &staging).unwrap_err();
        assert!(error.contains("Unsafe archive path"), "{error}");
        assert!(!root.join("escape.txt").exists());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn nested_package_layout_is_found() {
        let root = temp_dir("layout");
        let nested = root.join("llama-b6000-bin-win-cuda");
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join("llama-server.exe"), b"fake").unwrap();

        assert_eq!(
            find_llama_server(&root),
            Some(nested.join("llama-server.exe"))
        );

        let _ = fs::remove_dir_all(root);
    }
}
