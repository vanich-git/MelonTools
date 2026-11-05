//! Lifecycle management and supervision of the `llama-server` process.

use super::hardware::{detect_hardware, InferenceBackend};
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
use std::sync::atomic::{AtomicU64, Ordering};
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

/// Extracts the router's error message without losing the HTTP status when the
/// body is not JSON.
fn router_error_message(body: &str, status: u16) -> String {
    if let Ok(value) = serde_json::from_str::<Value>(body) {
        if let Some(message) = value
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(Value::as_str)
        {
            return message.to_string();
        }
        if let Some(message) = value.get("message").and_then(Value::as_str) {
            return message.to_string();
        }
    }
    let text = body.trim();
    if text.is_empty() {
        format!("HTTP {status}")
    } else {
        text.chars().take(512).collect()
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
async fn fetch_runtime_metrics(
    port: u16,
    token: &str,
    model_id: &str,
) -> Result<RuntimeMetrics, String> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .connect_timeout(Duration::from_secs(1))
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| format!("Failed to build metrics client: {}", e))?;

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
    if !matches!(url.scheme(), "http" | "https") {
        return Err("Runtime archive URL must use http or https".to_string());
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

fn load_custom_binary_path() -> Option<PathBuf> {
    let raw = fs::read_to_string(custom_binary_path_file()).ok()?;
    let path = PathBuf::from(raw.trim());
    path.is_file().then_some(path)
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

/// Reads every model's router state. `None` means the request or the pinned
/// response shape failed; an empty map is a valid "router lists nothing".
async fn fetch_router_models(
    client: &reqwest::Client,
    port: u16,
    token: &str,
) -> Option<HashMap<String, RouterModelState>> {
    let response = client
        .get(format!("http://127.0.0.1:{}/models", port))
        .bearer_auth(token)
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body = response.text().await.ok()?;
    parse_router_models(&body)
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

pub struct LocalRuntimeManager {
    inner: Arc<Mutex<RuntimeInner>>,
    installer: RuntimeInstaller,
    /// Last lifecycle revision whose effects were published to the gateway.
    published_gateway: AtomicU64,
    /// Serializes start/stop: only the holder may spawn, kill or publish a
    /// lifecycle state. A waiting start is cancelled before it gets the lock.
    lifecycle: tokio::sync::Mutex<()>,
    /// Broadcasts the newest lifecycle generation. A start waiting on health
    /// uses it to notice immediately that a stop or another start superseded
    /// it, instead of discovering that 30 seconds later through a timeout.
    lifecycle_changed: watch::Sender<u64>,
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
                LocalModelStore::update_model_status(&model.id, ModelRuntimeStatus::Installed);
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
            // Keep `current_model` so `failedModelId` still names the card
            // that has to show the error.
            let model_id = self.current_model.as_ref().map(|model| model.id.clone());
            let error = format!("llama-server exited unexpectedly ({})", status);
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

fn status_payload(snapshot: StatusSnapshot, binary_path: Option<String>) -> RuntimeStatusPayload {
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
    }
}

impl Default for LocalRuntimeManager {
    fn default() -> Self {
        Self::new()
    }
}

impl LocalRuntimeManager {
    pub fn new() -> Self {
        RuntimeInner::normalize_stale_statuses();
        Self {
            inner: Arc::new(Mutex::new(RuntimeInner {
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
            })),
            installer: RuntimeInstaller::new(),
            published_gateway: AtomicU64::new(0),
            lifecycle: tokio::sync::Mutex::new(()),
            lifecycle_changed: {
                let (sender, _receiver) = watch::channel(0);
                sender
            },
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
        self.published_gateway.fetch_max(revision, Ordering::AcqRel);
    }

    /// Side-effect free manager for the regression tests: no token file, no
    /// registry rewrite, no binary lookup on the real machine.
    #[cfg(test)]
    fn for_test() -> Self {
        Self {
            inner: Arc::new(Mutex::new(RuntimeInner {
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
            })),
            installer: RuntimeInstaller::new(),
            published_gateway: AtomicU64::new(0),
            lifecycle: tokio::sync::Mutex::new(()),
            lifecycle_changed: {
                let (sender, _receiver) = watch::channel(0);
                sender
            },
        }
    }

    /// Persists the explicit choice so a runtime installed into
    /// `runtime/packages/<id>` stays selected after a restart instead of
    /// falling back to PATH.
    pub fn set_custom_binary_path(&self, path: Option<PathBuf>) {
        let path = path.filter(|candidate| !candidate.as_os_str().is_empty());
        {
            let mut inner = self.inner.lock().unwrap();
            inner.custom_binary_path = path.clone();
        }
        let file = custom_binary_path_file();
        match path {
            Some(path) => {
                if let Some(parent) = file.parent() {
                    let _ = fs::create_dir_all(parent);
                }
                let _ = fs::write(&file, path.to_string_lossy().as_bytes());
            }
            None => {
                let _ = fs::remove_file(&file);
            }
        }
    }

    pub fn binary_path(&self) -> Option<PathBuf> {
        let inner = self.inner.lock().unwrap();
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

        // 2. Check PATH
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
        self.inner.lock().unwrap().port
    }

    pub fn token(&self) -> String {
        self.inner.lock().unwrap().token.clone()
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

        let path = local_metadata_dir().join("models.ini");
        std::fs::write(&path, lines.join("\n") + "\n")
            .map_err(|e| format!("Failed to write models preset: {}", e))?;
        Ok(path)
    }

    fn parallel_requests() -> usize {
        std::env::var("MELON_LOCAL_PARALLEL")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(1)
    }

    fn idle_unload_seconds() -> u64 {
        std::env::var("MELON_LOCAL_IDLE_UNLOAD")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0)
    }

    /// One snapshot of the runtime state.
    ///
    /// The lock is released before `binary_path()` is called: it takes the
    /// same non-reentrant `Mutex`, so doing it under the guard deadlocked
    /// every status poll (and with it Start/Stop/metrics/delete).
    pub fn get_status(&self) -> RuntimeStatusPayload {
        let (snapshot, registry_update) = {
            let mut inner = self.inner.lock().unwrap_or_else(|error| error.into_inner());
            let registry_update = inner.settle();
            (StatusSnapshot::capture(&inner), registry_update)
        };

        if let Some((model_id, status)) = registry_update {
            LocalModelStore::update_model_status(&model_id, status);
        }

        // Safe now: the guard above is gone.
        let binary_path = self
            .binary_path()
            .map(|path| path.to_string_lossy().to_string());
        status_payload(snapshot, binary_path)
    }

    pub fn find_available_port(start: u16) -> u16 {
        for candidate in start..(start + 31) {
            if let Ok(listener) = TcpListener::bind(("127.0.0.1", candidate)) {
                drop(listener);
                return candidate;
            }
        }
        start
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
        LocalModelStore::update_model_status(model_id, status);
    }

    fn superseded_message() -> String {
        "Local AI start was superseded by a newer start/stop request.".to_string()
    }

    /// Kills a process this launch owns after it was superseded, so a start
    /// that lost the race never leaves an orphan behind. Only the lifecycle
    /// holder can call it, which guarantees the child is its own.
    fn discard_child(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut child) = inner.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Kills the engine this manager owns and publishes `Stopped`. The caller
    /// must hold `lifecycle` and must still own the current generation.
    fn stop_locked(&self) {
        let prev_model_id;
        {
            let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(mut child) = inner.child.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
            prev_model_id = inner.current_model.as_ref().map(|m| m.id.clone());
            inner.current_model = None;
            inner.applied_settings = None;
            inner.transition(LocalRuntimeState::Stopped);
        }

        // The registry status follows the engine, not the process handle: a
        // crash already dropped the child, and a leftover `Ready` would keep
        // the model advertised by the gateway after it stopped.
        if let Some(ref id) = prev_model_id {
            LocalModelStore::update_model_status(id, ModelRuntimeStatus::Installed);
        }
        // The router is gone, so no model may stay warm: drop every leftover
        // transient status, not just the model that was current at stop.
        RuntimeInner::normalize_stale_statuses();
    }

    pub async fn stop(&self) {
        let (generation, _cancelled) = self.begin_lifecycle();
        let _guard = self.lifecycle.lock().await;
        // A newer start was requested while this stop waited for the lock. It
        // owns the engine now, so this stop must not kill that process.
        if !self.is_current_generation(generation) {
            return;
        }
        self.stop_locked();
    }

    /// Publishes a terminal launch failure only for the current generation.
    /// A superseded launch returns false and leaves the new state alone.
    fn fail_launch(&self, generation: u64, model_id: &str, error: &str) -> bool {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            return false;
        }
        if let Some(mut child) = inner.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        inner.applied_settings = None;
        inner.transition(LocalRuntimeState::Failed {
            error: error.to_string(),
        });
        drop(inner);
        self.update_model_status_if_current(generation, model_id, ModelRuntimeStatus::Error);
        true
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
        let already_loaded = tokio::select! {
            _ = wait_for_lifecycle_change(cancelled, generation) => {
                return Err(Self::superseded_message());
            }
            states = fetch_router_models(client, port, token) => states,
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

            let states = tokio::select! {
                _ = wait_for_lifecycle_change(cancelled, generation) => {
                    return Err(Self::superseded_message());
                }
                states = fetch_router_models(client, port, token) => states,
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
        self.stop_locked();

        let bin = self.binary_path().ok_or_else(|| {
            "llama-server executable not found. Please place llama-server in the runtime directory or specify its path in settings.".to_string()
        })?;

        let models_dir = LocalModelStore::models_dir();
        let model_file_path = if let Some(first) = model.files.first() {
            if Path::new(first).is_absolute() {
                PathBuf::from(first)
            } else {
                models_dir.join(first)
            }
        } else {
            return Err("Model has no files specified".to_string());
        };

        if !model_file_path.exists() {
            self.update_model_status_if_current(
                generation,
                &model.id,
                ModelRuntimeStatus::NotInstalled,
            );
            return Err(format!(
                "Model file does not exist: {}",
                model_file_path.display()
            ));
        }

        let port = Self::find_available_port(18318);
        save_runtime_port(port);
        let token = get_or_create_internal_token();

        // The gateway is pointed at the prompt relay, which forwards to this
        // port. Started before the config is written so the URL is live.
        super::system_prompt_proxy::set_upstream(port);
        super::system_prompt_proxy::ensure_started();

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

        let hw = detect_hardware(Some(&models_dir));
        // Router mode: the engine serves every installed model and loads them
        // on demand, matching the macOS implementation (§4.3).
        let preset_path =
            match Self::write_models_preset(&models_dir, hw.recommended_backend, hw.cpu_cores) {
                Ok(path) => path,
                Err(error) => {
                    // The state is already Starting: returning without a
                    // terminal transition would leave the UI waiting forever.
                    if !self.fail_launch(generation, &model.id, &error) {
                        return Err(Self::superseded_message());
                    }
                    return Err(error);
                }
            };
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
            "1".to_string(),
            "--metrics".to_string(),
        ];

        let parallel = Self::parallel_requests();
        if parallel > 1 {
            args.push("--parallel".to_string());
            args.push(parallel.to_string());
        }
        let idle = Self::idle_unload_seconds();
        if idle > 0 {
            args.push("--sleep-idle-seconds".to_string());
            args.push(idle.to_string());
        }

        let log_file_path = local_logs_dir().join("llama-server.log");
        let log_sink =
            match EngineLogSink::open(&log_file_path, ENGINE_LOG_MAX_BYTES, ENGINE_LOG_BACKUPS) {
                Ok(sink) => Arc::new(Mutex::new(sink)),
                Err(error) => {
                    if !self.fail_launch(generation, &model.id, &error) {
                        return Err(Self::superseded_message());
                    }
                    return Err(error);
                }
            };

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

        let mut child = cmd.spawn().map_err(|e| {
            let msg = format!("Failed to spawn llama-server: {}", e);
            if self
                .transition_if_current(generation, LocalRuntimeState::Failed { error: msg.clone() })
            {
                self.update_model_status_if_current(
                    generation,
                    &model.id,
                    ModelRuntimeStatus::Error,
                );
            }
            msg
        })?;
        // Same kill-on-close job as the gateway: an app crash or the updater's
        // exit must not leave the engine holding RAM and its port.
        let pid = child.id();
        if pid != 0 {
            if let Err(error) = crate::engine_job::assign(pid) {
                let _ = child.kill();
                let _ = child.wait();
                let message = format!("Cannot contain the Local AI process safely: {error}");
                if self.transition_if_current(
                    generation,
                    LocalRuntimeState::Failed {
                        error: message.clone(),
                    },
                ) {
                    self.update_model_status_if_current(
                        generation,
                        &model.id,
                        ModelRuntimeStatus::Error,
                    );
                }
                return Err(message);
            }
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
            let _ = child.kill();
            let _ = child.wait();
            return Err(Self::superseded_message());
        }

        // Health check loop: wait up to 30 seconds for llama-server to be ready
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_millis(1500))
            .build()
            .unwrap_or_default();
        let health_url = format!("http://127.0.0.1:{}/health", port);

        let mut ready = false;
        for _ in 0..60 {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_millis(500)) => {}
                _ = wait_for_lifecycle_change(&mut cancelled, generation) => {
                    self.discard_child();
                    return Err(Self::superseded_message());
                }
            }
            if !self.is_current_generation(generation) {
                self.discard_child();
                return Err(Self::superseded_message());
            }

            // Verify process hasn't exited prematurely
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
                let err = format!("llama-server exited prematurely with status {}", status);
                self.fail_launch(generation, &model.id, &err);
                return Err(err);
            }

            let resp = tokio::select! {
                _ = wait_for_lifecycle_change(&mut cancelled, generation) => {
                    self.discard_child();
                    return Err(Self::superseded_message());
                }
                resp = client
                    .get(&health_url)
                    .header("Authorization", format!("Bearer {}", token))
                    .send() => resp,
            };
            if !self.is_current_generation(generation) {
                self.discard_child();
                return Err(Self::superseded_message());
            }

            if let Ok(r) = resp {
                if r.status().is_success() {
                    ready = true;
                    break;
                }
            }
        }

        if !ready {
            let err = "llama-server healthcheck timed out after 30 seconds".to_string();
            self.fail_launch(generation, &model.id, &err);
            return Err(err);
        }

        // Health only proves the HTTP router is up. The model must be loaded
        // into the router before the runtime is Running and the gateway may
        // advertise it.
        if let Err(error) = self
            .load_model_into_router(generation, &mut cancelled, &client, port, &token, &model.id)
            .await
        {
            if error == Self::superseded_message() {
                self.discard_child();
            } else {
                self.fail_launch(generation, &model.id, &error);
            }
            return Err(error);
        }

        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            drop(inner);
            self.discard_child();
            return Err(Self::superseded_message());
        }
        inner.applied_settings = Some(model.user_settings.clone());
        inner.transition(LocalRuntimeState::Running {
            port,
            model_id: model.id.clone(),
        });
        drop(inner);
        self.update_model_status_if_current(generation, &model.id, ModelRuntimeStatus::Ready);
        Ok(())
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

        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap_or_default();
        let Some(states) = fetch_router_models(&client, port, &token).await else {
            return;
        };
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
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.generation != generation {
            return;
        }
        if !matches!(&inner.state, LocalRuntimeState::Running { port: current, .. } if *current == port)
        {
            return;
        }
        for (model_id, status) in changes {
            LocalModelStore::update_model_status(&model_id, status);
        }
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
    #[test]
    fn a_failed_launch_step_publishes_failed_instead_of_staying_starting() {
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

        assert!(manager.fail_launch(generation, model_id, "No installed model files to serve."));

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
            "CUDA out of memory"
        );
        assert_eq!(
            router_error_message(r#"{"message":"bad preset"}"#, 400),
            "bad preset"
        );
        assert_eq!(router_error_message("  plain body \n", 502), "plain body");
        assert_eq!(router_error_message("", 503), "HTTP 503");
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
        let running = status_payload(StatusSnapshot::capture(&inner), None);
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
        let starting = status_payload(StatusSnapshot::capture(&inner), None);
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
        let failed = status_payload(StatusSnapshot::capture(&inner), None);
        assert_eq!(failed.error.as_deref(), Some("boom"));
        assert_eq!(failed.failed_model_id.as_deref(), Some("local/qwen"));
        assert!(!failed.is_running && !failed.is_starting);
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
    fn install_url_allows_http_but_not_credentials_or_other_schemes() {
        assert!(validate_install_url("https://example.com/runtime.zip").is_ok());
        assert!(validate_install_url("http://example.com/runtime.zip").is_ok());
        assert!(validate_install_url("http://user:pass@example.com/runtime.zip").is_err());
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
