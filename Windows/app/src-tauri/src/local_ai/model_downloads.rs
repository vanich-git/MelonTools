//! Download manager for remote GGUF model files with resumable transfers.
//!
//! A transfer is only ever published after the bytes have been verified:
//! size, GGUF magic and — when Hugging Face publishes one — the LFS SHA-256.
//! Until then the data lives in `downloads/<repo>/<file>.part` next to a
//! sidecar that records the upstream validator, so a resume can prove it is
//! appending to the same revision.

use super::hardware::{format_bytes, InferenceBackend};
use super::local_models::{
    LocalModel, LocalModelSettings, LocalModelStore, ModelCapability, ModelRuntimeStatus,
};
use crate::paths::local_downloads_dir;
use chrono::Utc;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::sync::watch;

/// Wire spelling is lower snake case (`downloading`, `completed`, …): the
/// renderer compares these strings directly, and a `Downloading`/`downloading`
/// mismatch silently broke cancel, counts and styles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DownloadStatus {
    Queued,
    Downloading,
    Paused,
    Completed,
    Failed,
    Canceled,
}

impl DownloadStatus {
    /// True while a task and a `.part` file exist. Only these states keep the
    /// Cancel button and the "active" badge.
    pub fn is_active(self) -> bool {
        matches!(self, Self::Queued | Self::Downloading | Self::Paused)
    }

    pub fn is_finished(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Canceled)
    }
}

/// One download as the renderer reads it. `progress` is a 0…1 fraction,
/// everything else is named exactly as `mt-pages.js` uses it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgress {
    pub model_id: String,
    pub repo_id: String,
    pub filename: String,
    pub bytes_downloaded: u64,
    pub total_bytes: u64,
    pub progress: f64,
    pub speed_bytes_per_sec: u64,
    pub speed_formatted: String,
    pub eta_seconds: Option<u64>,
    pub status: DownloadStatus,
    pub error: Option<String>,
}

impl DownloadProgress {
    fn queued(model_id: String, repo_id: String, filename: String) -> Self {
        Self {
            model_id,
            repo_id,
            filename,
            bytes_downloaded: 0,
            total_bytes: 0,
            progress: 0.0,
            speed_bytes_per_sec: 0,
            speed_formatted: String::new(),
            eta_seconds: None,
            status: DownloadStatus::Queued,
            error: None,
        }
    }
}

/// Upstream facts a resume has to agree with. Without this sidecar a leftover
/// `.part` cannot be trusted, so the transfer restarts from zero.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PartMeta {
    url: String,
    repo_id: String,
    filename: String,
    /// `ETag` (preferred) or `Last-Modified`, sent back as `If-Range`.
    validator: Option<String>,
    total_bytes: Option<u64>,
    sha256: Option<String>,
}

/// Outcome of [`ModelDownloadManager::claim_download`].
enum DownloadClaim {
    /// An active transfer already owns the id.
    AlreadyActive,
    /// The caller owns the id and must spawn its worker.
    Started(watch::Receiver<bool>),
}

pub struct ModelDownloadManager {
    downloads: Arc<Mutex<HashMap<String, DownloadProgress>>>,
    cancel_senders: Arc<Mutex<HashMap<String, watch::Sender<bool>>>>,
}

impl Default for ModelDownloadManager {
    fn default() -> Self {
        Self::new()
    }
}

impl ModelDownloadManager {
    pub fn new() -> Self {
        Self {
            downloads: Arc::new(Mutex::new(HashMap::new())),
            cancel_senders: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Stable order so the renderer's payload comparison does not see a new
    /// list on every poll.
    pub fn get_all_downloads(&self) -> Vec<DownloadProgress> {
        let map = self.downloads.lock().unwrap();
        let mut downloads: Vec<_> = map.values().cloned().collect();
        downloads.sort_by(|a, b| a.model_id.cmp(&b.model_id));
        downloads
    }

    pub fn get_download(&self, model_id: &str) -> Option<DownloadProgress> {
        let map = self.downloads.lock().unwrap();
        map.get(model_id).cloned()
    }

    pub fn cancel_download(&self, model_id: &str) {
        let mut senders = self.cancel_senders.lock().unwrap();
        if let Some(tx) = senders.remove(model_id) {
            let _ = tx.send(true);
        }
        let mut map = self.downloads.lock().unwrap();
        if let Some(dl) = map.get_mut(model_id) {
            if dl.status.is_active() {
                dl.status = DownloadStatus::Canceled;
                dl.speed_bytes_per_sec = 0;
                dl.speed_formatted.clear();
                dl.eta_seconds = None;
            }
        }
    }

    /// Drops finished entries. Called by "Clear completed": the UI could filter
    /// its own copy, but the next poll brought the rows straight back.
    pub fn clear_finished(&self) -> usize {
        let mut map = self.downloads.lock().unwrap();
        let before = map.len();
        map.retain(|_, dl| !dl.status.is_finished());
        before - map.len()
    }

    /// Takes exclusive ownership of one model id. The active check and both
    /// inserts happen under one acquisition: two concurrent starts that only
    /// checked first could both spawn a worker, and the second write would
    /// orphan the first worker's cancel channel while both appended to the
    /// same `.part` file.
    fn claim_download(&self, progress: DownloadProgress) -> DownloadClaim {
        let model_id = progress.model_id.clone();
        // Same order as `cancel_download` (senders, then downloads): the two
        // paths must take the locks consistently or they can deadlock.
        let mut senders = self.cancel_senders.lock().unwrap();
        let mut map = self.downloads.lock().unwrap();
        if map.get(&model_id).is_some_and(|dl| dl.status.is_active()) {
            return DownloadClaim::AlreadyActive;
        }
        let (cancel_tx, cancel_rx) = watch::channel(false);
        senders.insert(model_id.clone(), cancel_tx);
        map.insert(model_id, progress);
        DownloadClaim::Started(cancel_rx)
    }

    pub async fn start_download(
        &self,
        repo_id: String,
        filename: String,
        download_url: String,
        quantization: String,
        token: Option<String>,
        expected_sha256: Option<String>,
    ) -> Result<String, String> {
        let filename = sanitize_filename(&filename)?;
        if !filename.to_lowercase().ends_with(".gguf") {
            return Err("Only .gguf files can be downloaded as models.".to_string());
        }
        let download_url = validate_download_url(&download_url)?;
        let expected_sha256 = normalize_sha256(expected_sha256.as_deref())?;
        // A damaged registry is read-only: publishing more bytes it cannot
        // record would leave an invisible file on disk.
        let health = LocalModelStore::registry_health();
        if health.read_only {
            return Err(health.error.unwrap_or_default());
        }

        let model_id = download_model_id(&repo_id, &filename);

        LocalModelStore::ensure_directories()?;

        let queued = DownloadProgress::queued(model_id.clone(), repo_id.clone(), filename.clone());
        let mut cancel_rx = match self.claim_download(queued) {
            DownloadClaim::AlreadyActive => return Ok(model_id),
            DownloadClaim::Started(receiver) => receiver,
        };

        let downloads_arc = Arc::clone(&self.downloads);
        let cancel_senders = Arc::clone(&self.cancel_senders);
        let model_id_clone = model_id.clone();

        tokio::spawn(async move {
            let res = Self::download_worker(
                model_id_clone.clone(),
                repo_id,
                filename,
                download_url,
                quantization,
                token,
                expected_sha256,
                downloads_arc.clone(),
                &mut cancel_rx,
            )
            .await;

            if let Err(e) = res {
                let mut map = downloads_arc.lock().unwrap();
                if let Some(dl) = map.get_mut(&model_id_clone) {
                    if dl.status != DownloadStatus::Canceled {
                        dl.status = DownloadStatus::Failed;
                        dl.error = Some(e);
                        dl.speed_bytes_per_sec = 0;
                        dl.speed_formatted.clear();
                        dl.eta_seconds = None;
                    }
                }
            }
            // Drop the cancel channel only while this worker still owns the
            // entry: a restart that claimed the id while this task was ending
            // must keep its own sender, or cancel would reach nothing.
            let mut senders = cancel_senders.lock().unwrap();
            let map = downloads_arc.lock().unwrap();
            let ours = match map.get(&model_id_clone) {
                Some(dl) => !dl.status.is_active(),
                None => true,
            };
            if ours {
                senders.remove(&model_id_clone);
            }
        });

        Ok(model_id)
    }

    #[allow(clippy::too_many_arguments)]
    async fn download_worker(
        model_id: String,
        repo_id: String,
        filename: String,
        download_url: String,
        quantization: String,
        token: Option<String>,
        expected_sha256: Option<String>,
        downloads_arc: Arc<Mutex<HashMap<String, DownloadProgress>>>,
        cancel_rx: &mut watch::Receiver<bool>,
    ) -> Result<(), String> {
        let part_dir = local_downloads_dir().join(repo_slug(&repo_id));
        fs::create_dir_all(&part_dir)
            .map_err(|e| format!("Failed to create the downloads directory: {}", e))?;
        let part_path = part_dir.join(format!("{}.part", filename));
        let meta_path = part_meta_path(&part_path);
        // Every model publishes into its own managed directory: two repos
        // with the same GGUF file name must not overwrite each other.
        let final_dest = LocalModelStore::managed_model_dir(&model_id).join(&filename);

        // Resume only when the sidecar proves the bytes belong to the same
        // upstream revision. Anything else restarts from zero: splicing two
        // revisions is silent corruption when HF publishes no digest.
        let previous = read_part_meta(&meta_path);
        let mut resume_from = match &previous {
            Some(meta)
                if meta.validator.is_some()
                    && meta.url == download_url
                    && meta.filename == filename
                    && part_path.is_file() =>
            {
                fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0)
            }
            _ => 0,
        };
        if resume_from == 0 {
            let _ = fs::remove_file(&part_path);
            let _ = fs::remove_file(&meta_path);
        }

        let client = super::external_client()
            .map_err(|e| format!("Failed to build the download client: {}", e))?;
        let mut resp = send_request(
            &client,
            &download_url,
            token.as_deref(),
            resume_from,
            previous.as_ref().and_then(|meta| meta.validator.as_deref()),
        )
        .await?;

        // A range answer we cannot line up with the bytes on disk is discarded
        // instead of appended.
        if resume_from > 0 && resp.status() == reqwest::StatusCode::RANGE_NOT_SATISFIABLE {
            drop(resp);
            // The file may already be complete; verify before throwing it away.
            match verify_and_publish(&part_path, &final_dest, expected_sha256.as_deref()) {
                Ok(published) => {
                    let _ = fs::remove_file(&meta_path);
                    return Self::record_published(
                        published,
                        &model_id,
                        &repo_id,
                        &filename,
                        &quantization,
                        expected_sha256.as_deref(),
                        &downloads_arc,
                    );
                }
                Err(_) => {
                    let _ = fs::remove_file(&part_path);
                    let _ = fs::remove_file(&meta_path);
                    return Err(
                        "The server rejected the resume range and the partial file did not verify. The download was reset."
                            .to_string(),
                    );
                }
            }
        }

        if resume_from > 0 {
            let usable = resp.status() == reqwest::StatusCode::PARTIAL_CONTENT
                && content_range_start(resp.headers()) == Some(resume_from);
            if !usable {
                // Validator changed upstream (or the server ignored the range).
                drop(resp);
                resume_from = 0;
                let _ = fs::remove_file(&part_path);
                resp = send_request(&client, &download_url, token.as_deref(), 0, None).await?;
            }
        }

        let status = resp.status();
        let is_partial = status == reqwest::StatusCode::PARTIAL_CONTENT;
        if !status.is_success() && !is_partial {
            return Err(format!("Download failed with HTTP status: {}", status));
        }

        let content_length = resp.content_length().unwrap_or(0);
        // `Content-Range: bytes 100-199/200` carries the real total; for a
        // partial response `content_length` only covers the remaining slice,
        // and chunked responses omit it entirely.
        let content_range_total = resp
            .headers()
            .get(reqwest::header::CONTENT_RANGE)
            .and_then(|v| v.to_str().ok())
            .and_then(parse_content_range_total);
        let total_bytes = match (is_partial, content_range_total) {
            (true, Some(total)) => total,
            (true, None) => resume_from + content_length,
            (false, _) => content_length,
        };

        // Durable validator for the next resume. Preferred order: ETag (strong
        // per-revision), then Last-Modified.
        let validator = resp
            .headers()
            .get(reqwest::header::ETAG)
            .or_else(|| resp.headers().get(reqwest::header::LAST_MODIFIED))
            .and_then(|value| value.to_str().ok())
            .map(|value| value.to_string());
        write_part_meta(
            &meta_path,
            &PartMeta {
                url: download_url.clone(),
                repo_id: repo_id.clone(),
                filename: filename.clone(),
                validator,
                total_bytes: (total_bytes > 0).then_some(total_bytes),
                sha256: expected_sha256.clone(),
            },
        );

        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .append(is_partial)
            .truncate(!is_partial)
            .open(&part_path)
            .map_err(|e| format!("Failed to open part file: {}", e))?;

        if is_partial {
            let _ = file.seek(SeekFrom::End(0));
        }

        let mut downloaded = resume_from;
        {
            let mut map = downloads_arc.lock().unwrap();
            if let Some(dl) = map.get_mut(&model_id) {
                dl.status = DownloadStatus::Downloading;
                dl.bytes_downloaded = downloaded;
                dl.total_bytes = total_bytes;
                dl.progress = if total_bytes > 0 {
                    (downloaded as f64) / (total_bytes as f64)
                } else {
                    0.0
                };
            }
        }

        let mut stream = resp.bytes_stream();
        let mut last_instant = Instant::now();
        let mut last_bytes = downloaded;

        while let Some(chunk_res) = stream.next().await {
            if *cancel_rx.borrow() {
                let _ = file.flush();
                return Ok(());
            }

            let chunk = chunk_res.map_err(|e| format!("Download stream error: {}", e))?;
            file.write_all(&chunk)
                .map_err(|e| format!("Failed to write chunk: {}", e))?;
            downloaded += chunk.len() as u64;

            let now = Instant::now();
            let elapsed = now.duration_since(last_instant).as_secs_f64();
            if elapsed >= 0.5 {
                let bytes_diff = downloaded.saturating_sub(last_bytes);
                let speed = (bytes_diff as f64 / elapsed) as u64;
                last_instant = now;
                last_bytes = downloaded;

                let mut map = downloads_arc.lock().unwrap();
                if let Some(dl) = map.get_mut(&model_id) {
                    dl.bytes_downloaded = downloaded;
                    dl.speed_bytes_per_sec = speed;
                    dl.speed_formatted = format!("{}/s", format_bytes(speed));
                    dl.progress = if total_bytes > 0 {
                        (downloaded as f64) / (total_bytes as f64)
                    } else {
                        0.0
                    };
                    dl.eta_seconds = (speed > 0 && total_bytes > downloaded)
                        .then(|| (total_bytes - downloaded) / speed);
                }
            }
        }

        file.flush()
            .map_err(|e| format!("Failed to flush downloaded file: {}", e))?;
        drop(file);

        let published = verify_and_publish(&part_path, &final_dest, expected_sha256.as_deref())?;
        let _ = fs::remove_file(&meta_path);

        Self::record_published(
            published,
            &model_id,
            &repo_id,
            &filename,
            &quantization,
            expected_sha256.as_deref(),
            &downloads_arc,
        )
    }

    /// Registers the verified file and marks the row completed.
    fn finish_installed(
        model_id: &str,
        repo_id: &str,
        filename: &str,
        quantization: &str,
        expected_sha256: Option<String>,
        downloads_arc: &Arc<Mutex<HashMap<String, DownloadProgress>>>,
    ) -> Result<(), String> {
        // The slug drops the `/` that distinguishes `a/b-c` from `a-b/c`, so
        // two repositories can share one id. Replacing the row would orphan
        // the first file and silently point the library at the second.
        if let Some(existing) = LocalModelStore::get_model(model_id) {
            let same_install = existing.repo_id.as_deref() == Some(repo_id)
                && existing.files.iter().any(|file| {
                    Path::new(file).file_name() == Some(std::ffi::OsStr::new(filename))
                });
            if !same_install {
                return Err(format!(
                    "The model id '{}' already belongs to '{}'. Nothing was replaced.",
                    model_id, existing.display_name
                ));
            }
        }

        let dir = LocalModelStore::managed_model_dir(model_id);
        let final_dest = dir.join(filename);
        let downloaded = fs::metadata(&final_dest).map(|m| m.len()).unwrap_or(0);
        let stored_file = dir
            .file_name()
            .map(|name| format!("{}/{}", name.to_string_lossy(), filename))
            .unwrap_or_else(|| filename.to_string());

        // Register in models.json
        let now = Utc::now().to_rfc3339();
        let display_name = filename.trim_end_matches(".gguf").replace(['_', '-'], " ");
        // The badge the Mac card shows (`qwen35`) comes from the GGUF header.
        // A truncated or unusual download simply leaves it out.
        let architecture = crate::local_ai::local_models::parse_gguf_metadata(&final_dest)
            .ok()
            .map(|info| info.architecture)
            .filter(|value| !value.is_empty());

        let model = LocalModel {
            id: model_id.to_string(),
            schema_version: None,
            display_name,
            provider: "Local AI".to_string(),
            source: "huggingface".to_string(),
            repo_id: Some(repo_id.to_string()),
            revision: Some("main".to_string()),
            files: vec![stored_file],
            file_size: downloaded,
            quantization: quantization.to_string(),
            format: "GGUF".to_string(),
            context_length: 8192,
            configured_context: 8192,
            backend: InferenceBackend::Cpu,
            architecture,
            gpu_offload: None,
            threads: None,
            runtime_status: ModelRuntimeStatus::Installed,
            capabilities: vec![ModelCapability::Text, ModelCapability::Tools],
            installed_at: now.clone(),
            updated_at: now,
            last_used_at: None,
            license: None,
            checksum: expected_sha256,
            user_settings: LocalModelSettings::default(),
        };

        LocalModelStore::upsert_model(&model)?;

        let mut map = downloads_arc.lock().unwrap();
        if let Some(dl) = map.get_mut(model_id) {
            dl.status = DownloadStatus::Completed;
            dl.bytes_downloaded = downloaded;
            dl.total_bytes = downloaded;
            dl.progress = 1.0;
            dl.speed_bytes_per_sec = 0;
            dl.speed_formatted.clear();
            dl.eta_seconds = None;
            dl.error = None;
        }
        Ok(())
    }

    /// Commits the publish swap only once the registry records the new row.
    /// A failed write rolls the file back to the previous revision, so the
    /// stored row still describes the bytes on disk.
    fn record_published(
        published: Published,
        model_id: &str,
        repo_id: &str,
        filename: &str,
        quantization: &str,
        expected_sha256: Option<&str>,
        downloads_arc: &Arc<Mutex<HashMap<String, DownloadProgress>>>,
    ) -> Result<(), String> {
        match Self::finish_installed(
            model_id,
            repo_id,
            filename,
            quantization,
            expected_sha256.map(str::to_string),
            downloads_arc,
        ) {
            Ok(()) => {
                published.commit();
                Ok(())
            }
            Err(error) => {
                published.rollback();
                Err(error)
            }
        }
    }
}

// MARK: - Transfer helpers

async fn send_request(
    client: &reqwest::Client,
    url: &str,
    token: Option<&str>,
    resume_from: u64,
    validator: Option<&str>,
) -> Result<reqwest::Response, String> {
    let mut req = client.get(url);
    if let Some(token) = token {
        if !token.trim().is_empty() {
            req = req.header("Authorization", format!("Bearer {}", token.trim()));
        }
    }
    if resume_from > 0 {
        req = req.header("Range", format!("bytes={}-", resume_from));
        // `If-Range` makes the server answer 200 (full body) when the file
        // changed upstream, which is exactly the "start over" signal.
        if let Some(validator) = validator {
            req = req.header("If-Range", validator);
        }
    }
    req.send()
        .await
        .map_err(|e| format!("Network request failed: {}", e))
}

/// Rejects empty names, `.`/`..`, path separators, drive letters, control
/// characters and trailing dots/spaces (Windows strips those, which would
/// publish a file under a name the registry does not know).
pub(crate) fn sanitize_filename(raw: &str) -> Result<String, String> {
    let name = raw.trim();
    if name.is_empty() || name == "." || name == ".." {
        return Err("The model file name is empty.".to_string());
    }
    if name.contains(['/', '\\']) || name.contains(':') || name.contains('\0') {
        return Err(format!(
            "The model file name must not contain a path separator: {}",
            name
        ));
    }
    if name.chars().any(|c| c.is_control()) {
        return Err("The model file name contains control characters.".to_string());
    }
    if name.ends_with('.') || name.ends_with(' ') {
        return Err("The model file name ends with a dot or a space.".to_string());
    }
    // Reserved DOS device names cannot be created as files.
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    const RESERVED: &[&str] = &[
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    if RESERVED.contains(&stem.as_str()) {
        return Err(format!("`{}` is a reserved Windows file name.", name));
    }
    Ok(name.to_string())
}

/// Only HTTPS downloads are accepted: the URL comes from the renderer, and a
/// plaintext or credentialed URL would leak the HF token.
pub(crate) fn validate_download_url(raw: &str) -> Result<String, String> {
    let url = url::Url::parse(raw.trim()).map_err(|e| format!("Invalid download URL: {}", e))?;
    if url.scheme() != "https" {
        return Err("Downloads must use HTTPS.".to_string());
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("The download URL must not embed credentials.".to_string());
    }
    if url.host_str().is_none() {
        return Err("The download URL has no host.".to_string());
    }
    Ok(url.to_string())
}

/// A stable directory name for one repository, so two repositories that ship a
/// file with the same name never write into the same `.part`.
fn repo_slug(repo_id: &str) -> String {
    let mut slug: String = repo_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    slug = slug.trim_matches('-').to_string();
    if slug.is_empty() || slug == "." || slug == ".." {
        "unknown".to_string()
    } else {
        slug
    }
}

pub(crate) fn normalize_sha256(raw: Option<&str>) -> Result<Option<String>, String> {
    let Some(value) = raw else { return Ok(None) };
    let value = value.trim().to_lowercase();
    if value.is_empty() {
        return Ok(None);
    }
    if value.len() != 64 || !value.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("The expected SHA-256 must be 64 hexadecimal characters.".to_string());
    }
    Ok(Some(value))
}

fn part_meta_path(part: &Path) -> PathBuf {
    let mut name = part
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".json");
    part.with_file_name(name)
}

fn read_part_meta(path: &Path) -> Option<PartMeta> {
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

fn write_part_meta(path: &Path, meta: &PartMeta) {
    // Best effort: a missing sidecar only costs a restart, never correctness.
    if let Ok(raw) = serde_json::to_string(meta) {
        let _ = fs::write(path, raw);
    }
}

/// Registry id for a download. The full repo path is part of it: two owners
/// can publish a file with the same name, and `local/<repo>/<file>` last-segment
/// ids used to make the second download replace the first model.
pub(crate) fn download_model_id(repo_id: &str, filename: &str) -> String {
    let slug = |raw: &str| -> String {
        let cleaned: String = raw
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                    c.to_ascii_lowercase()
                } else {
                    '-'
                }
            })
            .collect();
        cleaned.trim_matches('-').to_string()
    };
    let repo = slug(repo_id);
    let file = slug(filename.trim_end_matches(".gguf"));
    let file = if file.is_empty() {
        "model".to_string()
    } else {
        file
    };
    if repo.is_empty() {
        format!("local/{file}")
    } else {
        format!("local/{repo}-{file}")
    }
}

/// Verification gate before publication: size, GGUF magic and the published
/// digest. Nothing is moved and no existing model is touched until all three
/// pass.
fn verify_and_publish(
    part_path: &Path,
    final_dest: &Path,
    expected_sha256: Option<&str>,
) -> Result<Published, String> {
    let written = fs::metadata(part_path)
        .map_err(|e| format!("The download did not produce a file: {}", e))?
        .len();
    if written == 0 {
        return Err("The download is empty.".to_string());
    }
    let meta = read_part_meta(&part_meta_path(part_path));
    if let Some(total) = meta.as_ref().and_then(|meta| meta.total_bytes) {
        if total > 0 && written != total {
            return Err(format!(
                "Incomplete download: {} of {} bytes",
                written, total
            ));
        }
    }

    verify_gguf_magic(part_path)?;

    // Compare the LFS digest when Hugging Face published one.
    if let Some(expected) = expected_sha256 {
        let expected = expected.trim().to_lowercase();
        if !expected.is_empty() {
            let actual = sha256_of_file(part_path)?;
            if actual != expected {
                let _ = fs::remove_file(part_path);
                return Err(
                    "SHA-256 mismatch: the file is corrupted or was replaced upstream.".to_string(),
                );
            }
        }
    }

    publish(part_path, final_dest)
}

/// A GGUF file starts with the four ASCII bytes `GGUF`. Checking this before
/// publishing catches an HTML error page saved with a `.gguf` name.
fn verify_gguf_magic(path: &Path) -> Result<(), String> {
    let mut file =
        fs::File::open(path).map_err(|e| format!("Failed to open the downloaded file: {}", e))?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic)
        .map_err(|_| "The downloaded file is too short to be a GGUF model.".to_string())?;
    if &magic != b"GGUF" {
        let _ = fs::remove_file(path);
        return Err("The downloaded file is not a GGUF model (magic header mismatch).".to_string());
    }
    Ok(())
}

/// Publishes `part` at `final_dest` without deleting the existing model first.
///
/// A finished [`publish`] swap the registry has not recorded yet.
///
/// The previous revision waits on disk as `.<name>.<stamp>.bak` until
/// [`Self::commit`]: a registry write that fails must give the old model back
/// instead of leaving a stored row that describes bytes nobody verified.
struct Published {
    final_dest: PathBuf,
    backup: Option<PathBuf>,
}

impl Published {
    /// The registry now carries the new row: the previous revision can go.
    fn commit(self) {
        if let Some(backup) = self.backup {
            let _ = fs::remove_file(backup);
        }
    }

    /// The registry write failed: drop the unrecorded bytes and put the
    /// previous revision back. A new file that cannot be removed leaves the
    /// backup untouched instead of overwriting the only remaining copy.
    fn rollback(self) {
        match self.backup {
            Some(backup) => {
                if fs::remove_file(&self.final_dest).is_ok() {
                    let _ = fs::rename(backup, &self.final_dest);
                }
            }
            None => {
                let _ = fs::remove_file(&self.final_dest);
            }
        }
    }
}

/// Moves the verified `part_path` onto `final_dest`.
///
/// The new bytes are moved onto the destination volume as a temporary file,
/// the old file is renamed aside, and only then does the swap happen. If any
/// step fails the previous model is put back.
fn publish(part_path: &Path, final_dest: &Path) -> Result<Published, String> {
    let Some(parent) = final_dest.parent() else {
        return Err("The models directory is not a directory.".to_string());
    };
    fs::create_dir_all(parent)
        .map_err(|e| format!("Failed to create the models directory: {}", e))?;
    let file_name = final_dest
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("model.gguf");
    let stamp = uuid::Uuid::new_v4();
    let staged = parent.join(format!(".{}.{}.tmp", file_name, stamp));

    // A rename inside one volume is atomic; across volumes it fails with
    // ERROR_NOT_SAME_DEVICE and the bytes are copied instead.
    if let Err(rename_error) = fs::rename(part_path, &staged) {
        fs::copy(part_path, &staged).map_err(|copy_error| {
            format!(
                "Failed to stage the model next to {}: {} (rename: {})",
                final_dest.display(),
                copy_error,
                rename_error
            )
        })?;
    }

    let backup = parent.join(format!(".{}.{}.bak", file_name, stamp));
    let had_previous = final_dest.exists();
    if had_previous {
        if let Err(error) = fs::rename(final_dest, &backup) {
            let _ = fs::remove_file(&staged);
            return Err(format!(
                "Failed to move the previous model aside: {}",
                error
            ));
        }
    }

    match fs::rename(&staged, final_dest) {
        Ok(()) => {
            let _ = fs::remove_file(part_path);
            Ok(Published {
                final_dest: final_dest.to_path_buf(),
                backup: had_previous.then_some(backup),
            })
        }
        Err(error) => {
            if had_previous {
                let _ = fs::rename(&backup, final_dest);
            }
            let _ = fs::remove_file(&staged);
            Err(format!(
                "Failed to move the finished model to {}: {}",
                final_dest.display(),
                error
            ))
        }
    }
}

/// Streaming SHA-256 so a multi-gigabyte model is never read into memory.
fn sha256_of_file(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};

    let mut file =
        fs::File::open(path).map_err(|e| format!("Failed to open for hashing: {}", e))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|e| format!("Failed to read for hashing: {}", e))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect())
}

/// Reads the total size out of a `Content-Range` header, e.g.
/// `bytes 0-1023/4096` or `bytes */4096`. Returns `None` for an unknown
/// total (`*`) or a malformed header.
pub(crate) fn parse_content_range_total(header: &str) -> Option<u64> {
    let (_, total) = header.rsplit_once('/')?;
    let total = total.trim();
    if total.is_empty() || total == "*" {
        return None;
    }
    total.parse::<u64>().ok()
}

/// First byte position of a `Content-Range` answer, e.g. `bytes 1024-2047/4096`
/// → `Some(1024)`. A resume that starts anywhere else must not be appended.
fn content_range_start(headers: &reqwest::header::HeaderMap) -> Option<u64> {
    let header = headers.get(reqwest::header::CONTENT_RANGE)?.to_str().ok()?;
    let range = header.trim().strip_prefix("bytes")?.trim();
    let first = range.split('-').next()?.trim();
    first.parse::<u64>().ok()
}

#[cfg(test)]
mod tests {
    use super::{
        content_range_start, download_model_id, normalize_sha256, parse_content_range_total,
        publish, repo_slug, sanitize_filename, validate_download_url, verify_and_publish,
        DownloadClaim, DownloadProgress, DownloadStatus, ModelDownloadManager,
    };
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn two_repos_with_the_same_file_name_get_distinct_model_ids() {
        let first = download_model_id("acme/qwen", "Qwen3-4B-Q4_K_M.gguf");
        let second = download_model_id("other/qwen", "Qwen3-4B-Q4_K_M.gguf");
        assert_ne!(first, second);
        assert!(first.starts_with("local/acme-qwen-"));
        assert!(first.ends_with("qwen3-4b-q4_k_m"));
        // No path separators or spaces: the id is also the managed folder.
        for id in [&first, &second] {
            assert!(!id.contains('/') || id.starts_with("local/"));
            assert!(!id["local/".len()..].contains('/'));
            assert!(!id.contains(' '));
        }
    }

    #[test]
    fn content_range_total_reads_the_real_file_size() {
        // A partial body only reports the remaining slice in Content-Length,
        // so the total has to come from the header.
        assert_eq!(parse_content_range_total("bytes 0-1023/4096"), Some(4096));
        assert_eq!(parse_content_range_total("bytes 100-199/200"), Some(200));
        // Unsatisfied range: the total is still knowable.
        assert_eq!(parse_content_range_total("bytes */4096"), Some(4096));
    }

    #[test]
    fn content_range_total_rejects_unknown_and_malformed_values() {
        assert_eq!(parse_content_range_total("bytes 0-1023/*"), None);
        assert_eq!(parse_content_range_total("bytes 0-1023/"), None);
        assert_eq!(parse_content_range_total("4096"), None);
        assert_eq!(parse_content_range_total(""), None);
    }

    #[test]
    fn content_range_start_guards_a_resume() {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(
            reqwest::header::CONTENT_RANGE,
            "bytes 1024-2047/4096".parse().unwrap(),
        );
        assert_eq!(content_range_start(&headers), Some(1024));

        let empty = reqwest::header::HeaderMap::new();
        assert_eq!(content_range_start(&empty), None);
    }

    #[test]
    fn download_status_wire_spelling_is_lower_snake_case() {
        // The renderer compares these strings: `downloading`, `completed`,
        // `failed`, `canceled`.
        for (status, expected) in [
            (DownloadStatus::Queued, "queued"),
            (DownloadStatus::Downloading, "downloading"),
            (DownloadStatus::Paused, "paused"),
            (DownloadStatus::Completed, "completed"),
            (DownloadStatus::Failed, "failed"),
            (DownloadStatus::Canceled, "canceled"),
        ] {
            assert_eq!(
                serde_json::to_value(status).unwrap(),
                serde_json::json!(expected)
            );
        }

        let json = serde_json::to_value(DownloadProgress::queued(
            "local/a".to_string(),
            "org/repo".to_string(),
            "a.gguf".to_string(),
        ))
        .unwrap();
        for key in [
            "modelId",
            "repoId",
            "filename",
            "bytesDownloaded",
            "totalBytes",
            "progress",
            "speedBytesPerSec",
            "speedFormatted",
            "etaSeconds",
            "status",
        ] {
            assert!(json.get(key).is_some(), "missing `{}` in {}", key, json);
        }
        assert_eq!(json["status"], serde_json::json!("queued"));
    }

    #[test]
    fn clear_finished_drops_only_completed_rows() {
        let manager = super::ModelDownloadManager::new();
        {
            let mut map = manager.downloads.lock().unwrap();
            let mut done = DownloadProgress::queued(
                "local/done".to_string(),
                "org/repo".to_string(),
                "done.gguf".to_string(),
            );
            done.status = DownloadStatus::Completed;
            let mut running = DownloadProgress::queued(
                "local/run".to_string(),
                "org/repo".to_string(),
                "run.gguf".to_string(),
            );
            running.status = DownloadStatus::Downloading;
            map.insert(done.model_id.clone(), done);
            map.insert(running.model_id.clone(), running);
        }

        assert_eq!(manager.clear_finished(), 1);
        let left = manager.get_all_downloads();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].model_id, "local/run");
    }

    #[test]
    fn active_and_finished_states_do_not_overlap() {
        for status in [
            DownloadStatus::Queued,
            DownloadStatus::Downloading,
            DownloadStatus::Paused,
        ] {
            assert!(status.is_active());
            assert!(!status.is_finished());
        }
        for status in [
            DownloadStatus::Completed,
            DownloadStatus::Failed,
            DownloadStatus::Canceled,
        ] {
            assert!(!status.is_active());
            assert!(status.is_finished());
        }
    }

    #[test]
    fn file_names_cannot_escape_the_download_directory() {
        assert!(sanitize_filename("model.gguf").is_ok());
        // `sub/model.gguf` is a legal HF name but not a flat file name.
        assert!(sanitize_filename("sub/model.gguf").is_err());
        assert!(sanitize_filename("..\\..\\evil.gguf").is_err());
        assert!(sanitize_filename("/tmp/evil.gguf").is_err());
        assert!(sanitize_filename("C:evil.gguf").is_err());
        assert!(sanitize_filename("..").is_err());
        assert!(sanitize_filename("").is_err());
        assert!(sanitize_filename("con.gguf").is_err());
        assert!(sanitize_filename("model.gguf.").is_err());
        assert!(sanitize_filename("bad\nname.gguf").is_err());
    }

    #[test]
    fn only_https_downloads_without_credentials_are_accepted() {
        assert!(validate_download_url("https://huggingface.co/a/b/resolve/main/x.gguf").is_ok());
        assert!(validate_download_url("http://huggingface.co/a/b/x.gguf").is_err());
        assert!(validate_download_url("https://user:pass@huggingface.co/x.gguf").is_err());
        assert!(validate_download_url("file:///C:/x.gguf").is_err());
        assert!(validate_download_url("not a url").is_err());
    }

    #[test]
    fn a_colliding_download_id_cannot_replace_another_model() {
        use crate::local_ai::local_models::{with_test_root, LocalModelStore};
        use std::collections::HashMap;
        use std::sync::{Arc, Mutex};

        let root = temp_dir("id-collision");
        with_test_root(&root, || {
            let first_id = download_model_id("a/b-c", "same.gguf");
            let second_id = download_model_id("a-b/c", "same.gguf");
            assert_eq!(
                first_id, second_id,
                "the slash-to-dash slug is the collision under test"
            );

            let dir = LocalModelStore::managed_model_dir(&first_id);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("same.gguf"), b"GGUF").unwrap();
            let downloads = Arc::new(Mutex::new(HashMap::new()));

            ModelDownloadManager::finish_installed(
                &first_id,
                "a/b-c",
                "same.gguf",
                "Q4",
                None,
                &downloads,
            )
            .unwrap();
            let error = ModelDownloadManager::finish_installed(
                &second_id,
                "a-b/c",
                "same.gguf",
                "Q4",
                None,
                &downloads,
            )
            .unwrap_err();
            assert!(error.contains("already belongs"), "unexpected: {error}");

            let rows = LocalModelStore::load_registry();
            assert_eq!(rows.len(), 1, "the second download replaced the row");
            assert_eq!(rows[0].repo_id.as_deref(), Some("a/b-c"));
            assert!(dir.join("same.gguf").exists());
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn sha_256_must_be_64_hex_characters() {
        assert_eq!(normalize_sha256(None).unwrap(), None);
        assert_eq!(normalize_sha256(Some("  ")).unwrap(), None);
        let digest = "A".repeat(64);
        assert_eq!(
            normalize_sha256(Some(&digest)).unwrap(),
            Some("a".repeat(64))
        );
        assert!(normalize_sha256(Some("abc")).is_err());
        assert!(normalize_sha256(Some(&"z".repeat(64))).is_err());
    }

    #[test]
    fn repositories_get_distinct_part_directories() {
        assert_eq!(repo_slug("Qwen/Qwen3-4B-GGUF"), "qwen-qwen3-4b-gguf");
        assert_ne!(repo_slug("a/model"), repo_slug("b/model"));
        assert_eq!(repo_slug("///"), "unknown");
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "melon-download-{}-{}-{}",
            tag,
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn publish_replaces_a_previous_model_only_after_the_new_file_is_ready() {
        let dir = temp_dir("publish");
        let part = dir.join("model.gguf.part");
        let dest = dir.join("model.gguf");
        fs::write(&part, b"GGUFnew").unwrap();
        fs::write(&dest, b"GGUFold").unwrap();

        let published = publish(&part, &dest).unwrap();

        assert_eq!(fs::read(&dest).unwrap(), b"GGUFnew");
        assert!(!part.exists());
        // The previous revision waits for the registry write.
        assert!(published.backup.is_some());
        published.commit();
        // No stray staging/backup files are left behind.
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name.ends_with(".tmp") || name.ends_with(".bak"))
            .collect();
        assert!(leftovers.is_empty(), "left behind: {:?}", leftovers);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn publish_keeps_the_verified_download_when_the_destination_is_unusable() {
        let dir = temp_dir("publish-fail");
        let part = dir.join("model.gguf.part");
        fs::write(&part, b"GGUFnew").unwrap();
        // A plain file where the models directory should be makes the staging
        // step fail.
        let blocker = dir.join("blocked");
        fs::write(&blocker, b"not a directory").unwrap();
        let dest = blocker.join("model.gguf");

        assert!(publish(&part, &dest).is_err());
        // The verified download is not deleted by a failed publish.
        assert!(part.exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rolling_back_a_publish_restores_the_previous_revision() {
        let dir = temp_dir("publish-rollback");
        let part = dir.join("model.gguf.part");
        let dest = dir.join("model.gguf");
        fs::write(&part, b"GGUFnew").unwrap();
        fs::write(&dest, b"GGUFold").unwrap();

        let published = publish(&part, &dest).expect("publish");
        assert_eq!(fs::read(&dest).unwrap(), b"GGUFnew");
        published.rollback();

        assert_eq!(fs::read(&dest).unwrap(), b"GGUFold");
        // Nothing but the restored revision survives.
        let entries: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(entries, vec!["model.gguf".to_string()]);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rolling_back_a_first_install_removes_the_unrecorded_bytes() {
        let dir = temp_dir("publish-rollback-new");
        let part = dir.join("model.gguf.part");
        let dest = dir.join("model.gguf");
        fs::write(&part, b"GGUFnew").unwrap();

        let published = publish(&part, &dest).expect("publish");
        assert!(dest.exists());
        published.rollback();

        assert!(!dest.exists(), "an unrecorded model must not stay on disk");
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);

        let _ = fs::remove_dir_all(&dir);
    }

    fn queued(model_id: &str) -> DownloadProgress {
        DownloadProgress::queued(
            model_id.to_string(),
            "org/repo".to_string(),
            "model.gguf".to_string(),
        )
    }

    #[test]
    fn a_second_start_for_an_active_model_is_refused() {
        let manager = ModelDownloadManager::new();
        assert!(matches!(
            manager.claim_download(queued("local/one")),
            DownloadClaim::Started(_)
        ));
        assert!(matches!(
            manager.claim_download(queued("local/one")),
            DownloadClaim::AlreadyActive
        ));
        assert_eq!(manager.get_all_downloads().len(), 1);
        assert_eq!(
            manager.cancel_senders.lock().unwrap().len(),
            1,
            "a second start must not replace the cancel channel"
        );
    }

    #[test]
    fn a_finished_download_can_be_started_again() {
        let manager = ModelDownloadManager::new();
        assert!(matches!(
            manager.claim_download(queued("local/retry")),
            DownloadClaim::Started(_)
        ));
        manager.cancel_download("local/retry");
        assert_eq!(
            manager.get_download("local/retry").unwrap().status,
            DownloadStatus::Canceled
        );

        assert!(matches!(
            manager.claim_download(queued("local/retry")),
            DownloadClaim::Started(_)
        ));
        assert_eq!(manager.get_all_downloads().len(), 1);
        assert_eq!(manager.cancel_senders.lock().unwrap().len(), 1);
    }

    #[test]
    fn concurrent_starts_hand_out_one_owner_per_model() {
        use std::sync::{Arc, Barrier};

        let manager = Arc::new(ModelDownloadManager::new());
        let barrier = Arc::new(Barrier::new(8));
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let manager = Arc::clone(&manager);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    if matches!(
                        manager.claim_download(queued("local/raced")),
                        DownloadClaim::Started(_)
                    ) {
                        1usize
                    } else {
                        0usize
                    }
                })
            })
            .collect();
        let started: usize = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .sum();

        assert_eq!(started, 1, "exactly one worker may own the model id");
        assert_eq!(manager.get_all_downloads().len(), 1);
        assert_eq!(manager.cancel_senders.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_failed_registry_write_restores_the_previous_revision() {
        use crate::local_ai::hardware::InferenceBackend;
        use crate::local_ai::local_models::{
            fail_next_registry_save, with_test_root, LocalModel, LocalModelSettings,
            LocalModelStore, ModelCapability, ModelRuntimeStatus,
        };
        use std::collections::HashMap;
        use std::sync::{Arc, Mutex};

        fn installed_row(id: &str, file: &str, size: u64) -> LocalModel {
            LocalModel {
                id: id.to_string(),
                schema_version: Some(crate::schema::CURRENT),
                display_name: "installed".to_string(),
                provider: "Local AI".to_string(),
                source: "huggingface".to_string(),
                repo_id: Some("acme/repo".to_string()),
                revision: Some("main".to_string()),
                files: vec![file.to_string()],
                file_size: size,
                quantization: "Q4_K_M".to_string(),
                format: "GGUF".to_string(),
                context_length: 8192,
                configured_context: 8192,
                backend: InferenceBackend::Cpu,
                gpu_offload: None,
                threads: None,
                runtime_status: ModelRuntimeStatus::Installed,
                capabilities: vec![ModelCapability::Text],
                installed_at: "2026-01-01T00:00:00Z".to_string(),
                updated_at: "2026-01-01T00:00:00Z".to_string(),
                last_used_at: None,
                license: None,
                checksum: Some("previous-checksum".to_string()),
                architecture: None,
                user_settings: LocalModelSettings::default(),
            }
        }

        /// Smallest valid GGUF header: the parser and the magic check accept it.
        fn gguf(tag: &[u8]) -> Vec<u8> {
            let mut bytes = Vec::new();
            bytes.extend_from_slice(b"GGUF");
            bytes.extend_from_slice(&3u32.to_le_bytes());
            bytes.extend_from_slice(&0u64.to_le_bytes()); // tensor_count
            bytes.extend_from_slice(&0u64.to_le_bytes()); // kv_count
            bytes.extend_from_slice(tag);
            bytes
        }

        let old = gguf(b"old revision");
        let root = temp_dir("registry-rollback");
        fs::create_dir_all(root.join("metadata")).unwrap();
        with_test_root(&root, || {
            let dir = LocalModelStore::models_dir().join("managed");
            fs::create_dir_all(&dir).unwrap();
            let dest = dir.join("model.gguf");
            fs::write(&dest, &old).unwrap();
            let row = installed_row("local/managed", "managed/model.gguf", old.len() as u64);
            LocalModelStore::save_registry(std::slice::from_ref(&row)).unwrap();

            let part = root.join("downloads").join("model.gguf.part");
            fs::create_dir_all(part.parent().unwrap()).unwrap();
            fs::write(&part, gguf(b"new revision")).unwrap();

            let published = verify_and_publish(&part, &dest, None).expect("verify");
            fail_next_registry_save();
            let error = ModelDownloadManager::record_published(
                published,
                &row.id,
                "acme/repo",
                "model.gguf",
                "Q4_K_M",
                None,
                &Arc::new(Mutex::new(HashMap::new())),
            )
            .expect_err("the registry write must fail");
            assert!(error.contains("injected"), "unexpected error: {error}");

            // The bytes and the stored revision metadata are still the ones
            // that were installed before the failed write.
            assert_eq!(fs::read(&dest).unwrap(), old);
            let stored = LocalModelStore::get_model(&row.id).expect("the row survived");
            assert_eq!(stored.files, row.files);
            assert_eq!(stored.revision, row.revision);
            assert_eq!(stored.checksum, row.checksum);
        });
        let _ = fs::remove_dir_all(&root);
    }
}
