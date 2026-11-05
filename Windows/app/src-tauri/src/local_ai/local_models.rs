//! Local GGUF models registry, metadata parser, and storage management.

use super::hardware::{InferenceBackend, KvGeometry};
use crate::paths::{
    local_downloads_dir, local_logs_dir, local_metadata_dir, local_models_dir, local_runtime_dir,
    models_registry_path, storage_settings_path, tmp_path,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

// Tests must never read or write the real `%LOCALAPPDATA%` registry. The
// override is thread-local, so parallel tests in other modules stay unaffected.
#[cfg(test)]
thread_local! {
    static TEST_ROOT: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn test_root() -> Option<PathBuf> {
    TEST_ROOT.with(|slot| slot.borrow().clone())
}

#[cfg(test)]
pub(crate) fn with_test_root<T>(root: &Path, body: impl FnOnce() -> T) -> T {
    TEST_ROOT.with(|slot| *slot.borrow_mut() = Some(root.to_path_buf()));
    let result = body();
    TEST_ROOT.with(|slot| *slot.borrow_mut() = None);
    result
}

// The transaction rollbacks are only reachable when the registry write fails,
// and there is no portable way to make `models.json` unwritable from a test on
// every OS. This thread-local switch injects that one failure so the import and
// delete rollbacks are exercised for real. Production builds do not see it.
#[cfg(test)]
thread_local! {
    static FAIL_NEXT_SAVE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

#[cfg(test)]
pub(crate) fn fail_next_registry_save() {
    FAIL_NEXT_SAVE.with(|flag| flag.set(true));
}

#[cfg(test)]
fn take_injected_save_failure() -> bool {
    FAIL_NEXT_SAVE.with(|flag| flag.replace(false))
}

/// Fail-safe read state of `metadata/models.json`. A damaged registry must be
/// visible and read-only, never silently replaced by an empty list.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistryHealth {
    pub read_only: bool,
    pub error: Option<String>,
    /// Copy of the damaged file the user can inspect or restore.
    pub backup_path: Option<String>,
}

/// What one registry read found on disk.
enum RegistryRead {
    Missing,
    Loaded(Vec<LocalModel>),
    /// Parsed, but at least one row was written by a newer build: display it,
    /// refuse every write so its unknown fields cannot be dropped.
    LoadedReadOnly(Vec<LocalModel>, RegistryHealth),
    Damaged(RegistryHealth),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelRuntimeStatus {
    #[serde(rename = "not_installed")]
    NotInstalled,
    #[serde(rename = "downloading")]
    Downloading,
    #[serde(rename = "paused")]
    Paused,
    #[serde(rename = "verifying")]
    Verifying,
    #[serde(rename = "installed")]
    Installed,
    #[serde(rename = "loading")]
    Loading,
    #[serde(rename = "ready")]
    Ready,
    #[serde(rename = "generating")]
    Generating,
    #[serde(rename = "unloading")]
    Unloading,
    #[serde(rename = "error")]
    Error,
    #[serde(rename = "unsupported")]
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModelCapability {
    #[serde(rename = "text")]
    Text,
    #[serde(rename = "tools")]
    Tools,
    #[serde(rename = "vision")]
    Vision,
}

/// One wire spelling for the settings profile. The UI sends `auto`,
/// `performance`, `balanced`, `memory_saver` or `custom`; the aliases keep
/// registries written by older builds (and their PascalCase / spaced labels)
/// readable instead of failing the whole save.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelConfigProfile {
    #[serde(alias = "Auto", alias = "AUTO")]
    Auto,
    #[serde(alias = "Balanced", alias = "quality", alias = "Quality")]
    Balanced,
    #[serde(alias = "Performance", alias = "speed", alias = "Speed")]
    Performance,
    #[serde(
        alias = "Memory Saver",
        alias = "MemorySaver",
        alias = "low_memory",
        alias = "lowMemory"
    )]
    MemorySaver,
    #[serde(alias = "Custom")]
    Custom,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LocalModelSettings {
    pub context_length: usize,
    pub max_output_tokens: Option<usize>,
    pub temperature: f64,
    pub top_p: f64,
    pub top_k: usize,
    pub repeat_penalty: f64,
    pub seed: Option<i64>,
    pub cpu_threads: Option<usize>,
    pub gpu_offload_layers: Option<usize>,
    pub flash_attention: bool,
    pub kv_cache_type: String,
    pub batch_size: usize,
    pub chat_template: Option<String>,
    /// System prompt merged into every Chat Completions / Responses request the
    /// gateway serves for this model. `serde(default)` keeps registries written
    /// before the field existed decodable.
    #[serde(default)]
    pub system_prompt: Option<String>,
    pub profile: ModelConfigProfile,
    /// Thinking/reasoning pass. `None` means off, and `serde(default)` keeps
    /// registries written before the flag existed decodable.
    #[serde(default, alias = "reasoning")]
    pub reasoning_enabled: Option<bool>,
}

impl LocalModelSettings {
    /// Effective reasoning switch.
    pub fn is_reasoning_on(&self) -> bool {
        self.reasoning_enabled.unwrap_or(false)
    }

    /// Rejects values llama.cpp cannot run with, and keeps every value the
    /// user actually typed: zero is a real number here (temperature 0 is
    /// deterministic, top_k 0 disables the cut-off, seed 0 is a seed), so it
    /// is never treated as "unset".
    pub fn validate(&self) -> Result<(), String> {
        if !(512..=1_048_576).contains(&self.context_length) {
            return Err(format!(
                "Context length must be between 512 and 1048576 tokens (got {}).",
                self.context_length
            ));
        }
        if !self.temperature.is_finite() || !(0.0..=2.0).contains(&self.temperature) {
            return Err(format!(
                "Temperature must be a finite number between 0 and 2 (got {}).",
                self.temperature
            ));
        }
        if !self.top_p.is_finite() || !(0.0..=1.0).contains(&self.top_p) {
            return Err(format!(
                "Top-p must be a finite number between 0 and 1 (got {}).",
                self.top_p
            ));
        }
        if self.top_k > 1_000_000 {
            return Err(format!("Top-k is out of range ({}).", self.top_k));
        }
        if !self.repeat_penalty.is_finite() || !(0.0..=10.0).contains(&self.repeat_penalty) {
            return Err(format!(
                "Repeat penalty must be a finite number between 0 and 10 (got {}).",
                self.repeat_penalty
            ));
        }
        if !(1..=8192).contains(&self.batch_size) {
            return Err(format!(
                "Batch size must be between 1 and 8192 (got {}).",
                self.batch_size
            ));
        }
        if let Some(max_tokens) = self.max_output_tokens {
            if max_tokens > 131_072 {
                return Err(format!(
                    "Max output tokens is out of range ({}).",
                    max_tokens
                ));
            }
        }
        if self.kv_cache_type.trim().is_empty() {
            return Err("KV cache type must not be empty.".to_string());
        }
        Ok(())
    }
}

/// Partial settings update. Every field is optional so the UI can send only
/// what the user edited; everything else keeps the value already stored
/// instead of being reset to a default. `null` means "leave unchanged" for
/// the optional fields.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModelSettingsPatch {
    pub context_length: Option<usize>,
    pub max_output_tokens: Option<usize>,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
    pub top_k: Option<usize>,
    pub repeat_penalty: Option<f64>,
    pub seed: Option<i64>,
    pub cpu_threads: Option<usize>,
    pub gpu_offload_layers: Option<usize>,
    pub flash_attention: Option<bool>,
    pub kv_cache_type: Option<String>,
    pub batch_size: Option<usize>,
    pub chat_template: Option<String>,
    pub system_prompt: Option<String>,
    pub profile: Option<ModelConfigProfile>,
    #[serde(alias = "reasoning")]
    pub reasoning_enabled: Option<bool>,
}

impl LocalModelSettings {
    /// Applies a patch in place. Validation happens on the merged result, so a
    /// patch that only changes `temperature` still has to produce a settings
    /// object llama.cpp can start with.
    pub fn apply_patch(&mut self, patch: LocalModelSettingsPatch) -> Result<(), String> {
        if let Some(value) = patch.context_length {
            self.context_length = value;
        }
        if let Some(value) = patch.max_output_tokens {
            self.max_output_tokens = Some(value);
        }
        if let Some(value) = patch.temperature {
            self.temperature = value;
        }
        if let Some(value) = patch.top_p {
            self.top_p = value;
        }
        if let Some(value) = patch.top_k {
            self.top_k = value;
        }
        if let Some(value) = patch.repeat_penalty {
            self.repeat_penalty = value;
        }
        if let Some(value) = patch.seed {
            self.seed = Some(value);
        }
        if let Some(value) = patch.cpu_threads {
            // llama.cpp treats 0 threads as "pick automatically", which is the
            // same state as "unset" for the preset file.
            self.cpu_threads = (value > 0).then_some(value);
        }
        if let Some(value) = patch.gpu_offload_layers {
            self.gpu_offload_layers = Some(value);
        }
        if let Some(value) = patch.flash_attention {
            self.flash_attention = value;
        }
        if let Some(value) = patch.kv_cache_type {
            self.kv_cache_type = value;
        }
        if let Some(value) = patch.batch_size {
            self.batch_size = value;
        }
        if let Some(value) = patch.chat_template {
            let trimmed = value.trim().to_string();
            self.chat_template = (!trimmed.is_empty() && trimmed != "auto").then_some(trimmed);
        }
        if let Some(value) = patch.system_prompt {
            // Empty means "no prompt": an empty field clears a saved one.
            let trimmed = value.trim().to_string();
            self.system_prompt = (!trimmed.is_empty()).then_some(trimmed);
        }
        if let Some(value) = patch.profile {
            self.profile = value;
        }
        if let Some(value) = patch.reasoning_enabled {
            self.reasoning_enabled = Some(value);
        }
        self.validate()
    }
}

impl Default for LocalModelSettings {
    fn default() -> Self {
        Self {
            context_length: 8192,
            max_output_tokens: Some(4096),
            temperature: 0.7,
            top_p: 0.9,
            top_k: 40,
            repeat_penalty: 1.1,
            seed: None,
            cpu_threads: None,
            gpu_offload_layers: None,
            flash_attention: true,
            kv_cache_type: "f16".to_string(),
            batch_size: 512,
            chat_template: None,
            system_prompt: None,
            profile: ModelConfigProfile::Auto,
            reasoning_enabled: Some(false),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModel {
    pub id: String,
    /// Optional per-row persistence schema. Rows written by a newer build are
    /// displayed read-only instead of being re-saved without their new fields.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema_version: Option<u32>,
    pub display_name: String,
    pub provider: String,
    pub source: String,
    pub repo_id: Option<String>,
    pub revision: Option<String>,
    pub files: Vec<String>,
    pub file_size: u64,
    pub quantization: String,
    pub format: String,
    pub context_length: usize,
    pub configured_context: usize,
    pub backend: InferenceBackend,
    /// `general.architecture` read from the GGUF header, e.g. `qwen35`. Shown
    /// as a card badge, the way the Mac build reports it. Absent on rows
    /// imported before the field existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub architecture: Option<String>,
    pub gpu_offload: Option<usize>,
    pub threads: Option<usize>,
    pub runtime_status: ModelRuntimeStatus,
    pub capabilities: Vec<ModelCapability>,
    pub installed_at: String,
    pub updated_at: String,
    pub last_used_at: Option<String>,
    pub license: Option<String>,
    pub checksum: Option<String>,
    #[serde(default)]
    pub user_settings: LocalModelSettings,
}

/// Metadata read from a GGUF header.
#[derive(Debug, Clone, PartialEq)]
pub struct GgufInfo {
    pub version: u32,
    pub tensor_count: u64,
    /// `general.architecture`, e.g. "qwen2", "llama".
    pub architecture: String,
    pub name: Option<String>,
    /// `*.context_length` — the model's maximum, not the working context.
    pub context_length: usize,
    /// `*.block_count` — real transformer depth, used by memory estimation.
    pub block_count: usize,
    /// `*.attention.head_count` — query heads.
    pub head_count: usize,
    /// `*.attention.head_count_kv` — K/V heads. Equal to `head_count` for
    /// multi-head models and smaller for GQA/MQA ones.
    pub head_count_kv: usize,
    /// `*.embedding_length` — hidden width, used to derive the head size.
    pub embedding_length: usize,
    /// From `general.file_type`, falling back to the file name.
    pub quantization: String,
    pub chat_template: Option<String>,
    pub license: Option<String>,
}

impl GgufInfo {
    /// Layers for memory estimation; never zero.
    pub fn effective_layer_count(&self) -> usize {
        if self.block_count > 0 {
            self.block_count
        } else {
            32
        }
    }

    /// The geometry the KV-cache formula needs, when the header carries it.
    /// `None` means the caller has to fall back to a labelled heuristic.
    pub fn kv_geometry(&self) -> Option<super::hardware::KvGeometry> {
        let head_dim = if self.embedding_length > 0 && self.head_count > 0 {
            self.embedding_length / self.head_count
        } else {
            0
        };
        let kv_heads = if self.head_count_kv > 0 {
            self.head_count_kv
        } else {
            self.head_count
        };
        let geometry = super::hardware::KvGeometry {
            layers: self.block_count,
            kv_heads,
            head_dim,
        };
        geometry.is_complete().then_some(geometry)
    }
}

/// ggml `general.file_type` → quantization label (llama_ftype in llama.cpp).
fn file_type_name(value: u32) -> Option<&'static str> {
    Some(match value {
        0 => "F32",
        1 => "F16",
        2 => "Q4_0",
        3 => "Q4_1",
        7 => "Q8_0",
        8 => "Q5_0",
        9 => "Q5_1",
        10 => "Q2_K",
        11 => "Q3_K_S",
        12 => "Q3_K_M",
        13 => "Q3_K_L",
        14 => "Q4_K_S",
        15 => "Q4_K_M",
        16 => "Q5_K_S",
        17 => "Q5_K_M",
        18 => "Q6_K",
        19 => "IQ2_XXS",
        20 => "IQ2_XS",
        21 => "Q2_K_S",
        22 => "IQ3_XS",
        23 => "IQ3_XXS",
        24 => "IQ1_S",
        25 => "IQ4_NL",
        26 => "IQ3_S",
        27 => "IQ3_M",
        28 => "IQ2_S",
        29 => "IQ2_M",
        30 => "IQ4_XS",
        31 => "IQ1_M",
        32 => "BF16",
        36 => "Q4_0_4_8",
        37 => "Q4_0_8_8",
        38 => "TQ1_0",
        39 => "TQ2_0",
        40 => "MXFP4",
        _ => return None,
    })
}

/// Reads GGUF metadata without touching tensor data.
///
/// The earlier version returned hard-coded constants and guessed the
/// quantization from the file name, which the specification forbids.
pub fn parse_gguf_metadata(path: &Path) -> Result<GgufInfo, String> {
    use std::io::{BufReader, Read};

    let file = fs::File::open(path).map_err(|e| format!("Failed to open GGUF file: {}", e))?;
    let mut reader = BufReader::new(file);
    let mut bytes_read: u64 = 0;

    fn read_exact_at<R: Read>(r: &mut R, buf: &mut [u8], counter: &mut u64) -> Result<(), String> {
        r.read_exact(buf)
            .map_err(|e| format!("GGUF header is truncated: {}", e))?;
        *counter += buf.len() as u64;
        Ok(())
    }

    let mut magic = [0u8; 4];
    read_exact_at(&mut reader, &mut magic, &mut bytes_read)?;
    if &magic != b"GGUF" {
        return Err("Not a valid GGUF file (magic header mismatch)".to_string());
    }

    let mut buf4 = [0u8; 4];
    read_exact_at(&mut reader, &mut buf4, &mut bytes_read)?;
    let version = u32::from_le_bytes(buf4);
    if !(2..=3).contains(&version) {
        return Err(format!("Unsupported GGUF version: {}", version));
    }

    let mut buf8 = [0u8; 8];
    read_exact_at(&mut reader, &mut buf8, &mut bytes_read)?;
    let tensor_count = u64::from_le_bytes(buf8);
    read_exact_at(&mut reader, &mut buf8, &mut bytes_read)?;
    let kv_count = u64::from_le_bytes(buf8);

    fn read_u32<R: Read>(r: &mut R, c: &mut u64) -> Result<u32, String> {
        let mut b = [0u8; 4];
        r.read_exact(&mut b)
            .map_err(|e| format!("GGUF is truncated: {}", e))?;
        *c += 4;
        Ok(u32::from_le_bytes(b))
    }
    fn read_u64<R: Read>(r: &mut R, c: &mut u64) -> Result<u64, String> {
        let mut b = [0u8; 8];
        r.read_exact(&mut b)
            .map_err(|e| format!("GGUF is truncated: {}", e))?;
        *c += 8;
        Ok(u64::from_le_bytes(b))
    }
    fn read_string<R: Read>(r: &mut R, c: &mut u64) -> Result<String, String> {
        let len = read_u64(r, c)?;
        if len > 16 * 1024 * 1024 {
            return Err("GGUF string is implausibly large".to_string());
        }
        let mut data = vec![0u8; len as usize];
        r.read_exact(&mut data)
            .map_err(|e| format!("GGUF is truncated: {}", e))?;
        *c += len;
        Ok(String::from_utf8_lossy(&data).into_owned())
    }
    fn skip<R: Read>(r: &mut R, n: u64, c: &mut u64) -> Result<(), String> {
        let skipped = std::io::copy(&mut r.by_ref().take(n), &mut std::io::sink())
            .map_err(|e| format!("GGUF is truncated: {}", e))?;
        if skipped != n {
            return Err("GGUF is truncated".to_string());
        }
        *c += n;
        Ok(())
    }

    /// Numeric keys this parser cares about. Kept in one struct so the
    /// uint32 and uint64 branches share the same suffix matching instead of
    /// duplicating it (and drifting).
    #[derive(Default)]
    struct NumericFields {
        context_length: usize,
        block_count: usize,
        head_count: usize,
        head_count_kv: usize,
        embedding_length: usize,
        file_type: Option<u32>,
    }

    fn apply_numeric(fields: &mut NumericFields, key: &str, raw: u64) {
        if key == "general.file_type" {
            fields.file_type = u32::try_from(raw).ok();
            return;
        }
        // `qwen2.attention.head_count_kv` does not end with
        // `.attention.head_count`, so the narrow suffix wins for both.
        if key.ends_with(".attention.head_count_kv") {
            fields.head_count_kv = raw as usize;
        } else if key.ends_with(".attention.head_count") {
            fields.head_count = raw as usize;
        } else if key.ends_with(".embedding_length") {
            fields.embedding_length = raw as usize;
        } else if key.ends_with(".context_length") {
            fields.context_length = raw as usize;
        } else if key.ends_with(".block_count") {
            fields.block_count = raw as usize;
        }
    }

    let mut architecture = "llama".to_string();
    let mut name: Option<String> = None;
    let mut numeric = NumericFields::default();
    let mut chat_template: Option<String> = None;
    let mut license: Option<String> = None;

    for _ in 0..kv_count {
        let key = read_string(&mut reader, &mut bytes_read)?;
        let value_type = read_u32(&mut reader, &mut bytes_read)?;

        match value_type {
            // STRING
            8 => {
                let value = read_string(&mut reader, &mut bytes_read)?;
                match key.as_str() {
                    "general.architecture" => architecture = value,
                    "general.name" => name = Some(value),
                    "tokenizer.chat_template" => chat_template = Some(value),
                    "general.license" | "license" => license = Some(value),
                    _ => {}
                }
            }
            // ARRAY — vocab/merges are huge, skip the payload.
            9 => {
                let element_type = read_u32(&mut reader, &mut bytes_read)?;
                let length = read_u64(&mut reader, &mut bytes_read)?;
                match element_type {
                    8 => {
                        for _ in 0..length {
                            let len = read_u64(&mut reader, &mut bytes_read)?;
                            skip(&mut reader, len, &mut bytes_read)?;
                        }
                    }
                    7 | 0 | 1 => skip(&mut reader, length, &mut bytes_read)?,
                    2 | 3 => skip(&mut reader, length * 2, &mut bytes_read)?,
                    4..=6 => skip(&mut reader, length * 4, &mut bytes_read)?,
                    10..=12 => skip(&mut reader, length * 8, &mut bytes_read)?,
                    other => return Err(format!("Unsupported GGUF array element type: {}", other)),
                }
            }
            // BOOL / UINT8 / INT8
            7 | 0 | 1 => skip(&mut reader, 1, &mut bytes_read)?,
            // UINT16 / INT16
            2 | 3 => skip(&mut reader, 2, &mut bytes_read)?,
            // UINT32 / INT32 / FLOAT32
            4..=6 => {
                let raw = read_u32(&mut reader, &mut bytes_read)?;
                apply_numeric(&mut numeric, &key, u64::from(raw));
            }
            // UINT64 / INT64 / FLOAT64
            10..=12 => {
                let raw = read_u64(&mut reader, &mut bytes_read)?;
                apply_numeric(&mut numeric, &key, raw);
            }
            other => return Err(format!("Unsupported GGUF metadata value type: {}", other)),
        }
    }

    let quantization = numeric
        .file_type
        .and_then(file_type_name)
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            let file_name = path
                .file_name()
                .and_then(|f| f.to_str())
                .unwrap_or("")
                .to_uppercase();
            crate::local_ai::huggingface::extract_quantization(&file_name)
        });

    Ok(GgufInfo {
        version,
        tensor_count,
        architecture,
        name,
        context_length: numeric.context_length,
        block_count: numeric.block_count,
        head_count: numeric.head_count,
        head_count_kv: numeric.head_count_kv,
        embedding_length: numeric.embedding_length,
        quantization,
        chat_template,
        license,
    })
}

/// Filesystem-backed registry of installed local models.
///
/// The registry lives next to the models in `metadata/models.json`. Every
/// mutation rewrites it atomically through a temp file + rename, so a crash in
/// the middle cannot leave a half-written registry behind.
pub struct LocalModelStore;

/// Every read-modify-write of `models.json` takes this mutex. The native
/// supervisor rewrites model statuses every few seconds; without one lock an
/// import that finished between the supervisor's load and save would be wiped
/// by the stale snapshot, even though each write is atomic on its own.
static REGISTRY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn registry_lock() -> std::sync::MutexGuard<'static, ()> {
    REGISTRY_LOCK
        .lock()
        .unwrap_or_else(|error| error.into_inner())
}

impl LocalModelStore {
    /// Creates the managed storage tree: models, downloads, runtime,
    /// metadata, logs.
    pub fn ensure_directories() -> Result<(), String> {
        #[cfg(test)]
        if let Some(root) = test_root() {
            for name in ["models", "downloads", "runtime", "metadata", "logs"] {
                fs::create_dir_all(root.join(name)).map_err(|e| e.to_string())?;
            }
            return Ok(());
        }
        for dir in [
            local_models_dir(),
            local_downloads_dir(),
            local_runtime_dir(),
            local_metadata_dir(),
            local_logs_dir(),
        ] {
            fs::create_dir_all(&dir)
                .map_err(|e| format!("Failed to create {}: {}", dir.display(), e))?;
        }
        Ok(())
    }

    /// Managed models directory (honours the user's custom path).
    pub fn models_dir() -> PathBuf {
        #[cfg(test)]
        if let Some(root) = test_root() {
            return root.join("models");
        }
        if let Ok(raw) = fs::read_to_string(storage_settings_path()) {
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) {
                if let Some(path) = value
                    .get("customModelsPath")
                    .and_then(|v| v.as_str())
                    .filter(|p| !p.trim().is_empty())
                {
                    let candidate = PathBuf::from(path);
                    if candidate.is_dir() {
                        return candidate;
                    }
                }
            }
        }
        local_models_dir()
    }

    fn registry_path() -> PathBuf {
        #[cfg(test)]
        if let Some(root) = test_root() {
            return root.join("metadata").join("models.json");
        }
        models_registry_path()
    }

    /// Per-model managed subdirectory. Two different models whose source file
    /// has the same basename used to overwrite each other in `models/`.
    pub(crate) fn managed_model_dir(id: &str) -> PathBuf {
        let mut slug: String = id
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                    c
                } else {
                    '-'
                }
            })
            .collect();
        slug = slug.trim_matches(['-', '.']).to_string();
        if slug.is_empty() {
            slug.push_str("model");
        }
        Self::models_dir().join(slug)
    }

    /// Copies a damaged registry aside before the app refuses further writes.
    /// A copy with identical bytes is reused, so repeated reads do not fill the
    /// folder. Keeps the damaged bytes without ever overwriting an earlier
    /// rescue: a second corruption would otherwise delete the only copy that
    /// was still recoverable, so later revisions get numbered sidecars.
    fn quarantine_registry(path: &Path, data: &str) -> Option<PathBuf> {
        use std::io::Write;

        let mut index = 0_u64;
        loop {
            let backup = path.with_file_name(if index == 0 {
                "models.corrupt.bak".to_string()
            } else {
                format!("models.corrupt.{index}.bak")
            });
            match fs::read(&backup) {
                // Do not rewrite the known-good copy: disk-full/ACL failures
                // during a repeated read must not truncate the only rescue.
                Ok(bytes) if bytes == data.as_bytes() => return Some(backup),
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    match fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&backup)
                    {
                        Ok(mut file) => {
                            file.write_all(data.as_bytes()).ok()?;
                            file.sync_all().ok()?;
                            return Some(backup);
                        }
                        // A concurrent reader or dangling symlink reserved
                        // this name. Try another revision, never overwrite it.
                        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(_) => return None,
                    }
                }
                // Unreadable: never overwrite a rescue we cannot inspect.
                Err(_) => {}
            }
            index = index.checked_add(1)?;
        }
    }

    fn read_registry_at(path: &Path) -> RegistryRead {
        let data = match fs::read_to_string(path) {
            Ok(data) => data,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return RegistryRead::Missing
            }
            // Exists but cannot be read (ACL, locked file): never treat this
            // as an empty library, or the next save would replace it.
            Err(_) => {
                return RegistryRead::Damaged(RegistryHealth {
                    read_only: true,
                    error: Some(format!(
                        "The Local AI registry at {} could not be read. Nothing was changed.",
                        path.display()
                    )),
                    backup_path: None,
                })
            }
        };
        match serde_json::from_str::<Vec<LocalModel>>(&data) {
            Ok(models) => {
                if let Some(version) = models
                    .iter()
                    .filter_map(|model| model.schema_version)
                    .find(|version| *version > crate::schema::CURRENT)
                {
                    crate::schema::note_newer("local models", version);
                    return RegistryRead::LoadedReadOnly(
                        models,
                        RegistryHealth {
                            read_only: true,
                            error: Some(format!(
                                "The Local AI registry contains a model written by a newer Melon Tools (schema {version}, this build supports {}). Update the app before editing the library.",
                                crate::schema::CURRENT
                            )),
                            backup_path: None,
                        },
                    );
                }
                RegistryRead::Loaded(models)
            }
            Err(error) => {
                let backup = Self::quarantine_registry(path, &data);
                let where_copy = backup
                    .as_ref()
                    .map(|path| format!(" A copy is kept at {}.", path.display()))
                    .unwrap_or_default();
                RegistryRead::Damaged(RegistryHealth {
                    read_only: true,
                    error: Some(format!(
                        "The Local AI registry is damaged ({error}).{where_copy} Nothing was changed: restore that file or start a new library."
                    )),
                    backup_path: backup.map(|path| path.to_string_lossy().to_string()),
                })
            }
        }
    }

    /// Whether registry writes are currently refused because the file is
    /// damaged or unreadable.
    pub fn registry_health() -> RegistryHealth {
        match Self::read_registry_at(&Self::registry_path()) {
            RegistryRead::Missing | RegistryRead::Loaded(_) => RegistryHealth::default(),
            RegistryRead::LoadedReadOnly(_, health) | RegistryRead::Damaged(health) => health,
        }
    }

    /// Explicit user recovery: keep the damaged file as a backup, then start
    /// from an empty registry. Writes are blocked until this is called.
    pub fn recover_registry() -> Result<(), String> {
        let _guard = registry_lock();
        let path = Self::registry_path();
        match Self::read_registry_at(&path) {
            RegistryRead::Missing | RegistryRead::Loaded(_) => return Ok(()),
            // Parsed but newer: recovery would discard its unknown fields.
            RegistryRead::LoadedReadOnly(_, health) => {
                return Err(health.error.unwrap_or_else(|| {
                    "Update Melon Tools before resetting this registry.".to_string()
                }))
            }
            RegistryRead::Damaged(_) => {}
        }
        // `read_registry_at` already tried this; retry only to learn whether a
        // copy exists, and never delete the only readable revision without it.
        let backup = fs::read_to_string(&path)
            .ok()
            .and_then(|data| Self::quarantine_registry(&path, &data));
        if backup.is_none() {
            return Err(format!(
                "Failed to back up the damaged registry at {}; nothing was changed.",
                path.display()
            ));
        }
        fs::remove_file(&path)
            .map_err(|e| format!("Failed to remove the damaged registry: {e}"))?;
        Self::save_registry_at(&path, &[])
    }

    fn save_registry_at(path: &Path, models: &[LocalModel]) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let tmp = tmp_path(path);
        // Stamp the row schema so a future build can detect its own rows. The
        // caller's structs stay unchanged.
        let mut stored = models.to_vec();
        for model in &mut stored {
            model.schema_version = Some(crate::schema::CURRENT);
        }
        let data = serde_json::to_string_pretty(&stored)
            .map_err(|e| format!("Failed to serialize models registry: {}", e))?;
        fs::write(&tmp, data).map_err(|e| format!("Failed to write tmp registry: {}", e))?;
        fs::rename(&tmp, path).map_err(|e| format!("Failed to commit models registry: {}", e))
    }

    /// Reads the registry, correcting quantization labels that an older build
    /// derived from the file name instead of the GGUF metadata. A damaged file
    /// yields an empty list plus [`Self::registry_health`] reporting why.
    pub fn load_registry() -> Vec<LocalModel> {
        let mut models = match Self::read_registry_at(&Self::registry_path()) {
            RegistryRead::Loaded(models) | RegistryRead::LoadedReadOnly(models, _) => models,
            RegistryRead::Missing | RegistryRead::Damaged(_) => return Vec::new(),
        };

        for model in &mut models {
            let Some(file) = model.files.first() else {
                continue;
            };
            let full = Self::resolve_model_file(file);
            if let Ok(meta) = parse_gguf_metadata(&full) {
                if !meta.quantization.is_empty() && meta.quantization != model.quantization {
                    model.quantization = meta.quantization;
                }
                if meta.context_length > 0 {
                    model.context_length = meta.context_length;
                }
            }
        }
        models
    }

    /// Low-level replace. Callers doing read-modify-write must hold
    /// [`registry_lock`] (all store methods do); prefer [`Self::upsert_model`].
    pub fn save_registry(models: &[LocalModel]) -> Result<(), String> {
        Self::ensure_directories()?;
        let health = Self::registry_health();
        if health.read_only {
            return Err(health.error.unwrap_or_else(|| {
                "The Local AI registry is read-only until it is recovered.".to_string()
            }));
        }
        #[cfg(test)]
        {
            if take_injected_save_failure() {
                return Err("injected registry write failure".to_string());
            }
        }
        Self::save_registry_at(&Self::registry_path(), models)
    }

    /// Inserts or replaces one row under the registry lock, so a concurrent
    /// status monitor cannot resurrect a stale snapshot over it.
    pub fn upsert_model(model: &LocalModel) -> Result<(), String> {
        let _guard = registry_lock();
        let mut models = Self::load_registry();
        models.retain(|existing| existing.id != model.id);
        models.push(model.clone());
        Self::save_registry(&models)
    }

    pub fn get_model(id: &str) -> Option<LocalModel> {
        Self::load_registry().into_iter().find(|m| m.id == id)
    }

    /// Absolute path of a registry `files` entry. A relative name lives inside
    /// the managed models directory.
    pub fn resolve_model_file(file: &str) -> PathBuf {
        if Path::new(file).is_absolute() {
            PathBuf::from(file)
        } else {
            Self::models_dir().join(file)
        }
    }

    /// KV-cache geometry from the on-disk GGUF header. `None` means the file is
    /// unreadable or the header omits the head geometry, and the estimator has
    /// to fall back to its labelled heuristic.
    pub fn model_kv_geometry(model: &LocalModel) -> Option<KvGeometry> {
        let file = model.files.first()?;
        parse_gguf_metadata(&Self::resolve_model_file(file))
            .ok()?
            .kv_geometry()
    }

    /// Applies a partial settings update on top of what is already stored, so
    /// fields the dialog does not show (top-k, repeat penalty, batch size,
    /// chat template, seed, reasoning) survive a save instead of being
    /// overwritten with defaults.
    pub fn update_model_settings(
        id: &str,
        patch: LocalModelSettingsPatch,
    ) -> Result<LocalModel, String> {
        let _guard = registry_lock();
        let mut models = Self::load_registry();
        let Some(index) = models.iter().position(|m| m.id == id) else {
            return Err(format!("Model '{}' not found", id));
        };
        {
            let model = &mut models[index];
            let mut settings = model.user_settings.clone();
            settings.apply_patch(patch)?;
            model.configured_context = settings.context_length;
            model.gpu_offload = settings.gpu_offload_layers;
            model.threads = settings.cpu_threads;
            model.user_settings = settings;
            model.updated_at = Utc::now().to_rfc3339();
        }
        let updated = models[index].clone();
        Self::save_registry(&models)?;
        Ok(updated)
    }

    pub fn update_model_status(id: &str, status: ModelRuntimeStatus) {
        let _guard = registry_lock();
        let mut models = Self::load_registry();
        let Some(model) = models.iter_mut().find(|m| m.id == id) else {
            return;
        };
        model.runtime_status = status;
        model.updated_at = Utc::now().to_rfc3339();
        let _ = Self::save_registry(&models);
    }

    /// Removes a model from the registry and deletes only files that live
    /// inside the managed directory and are not referenced by another entry.
    /// A model imported by reference keeps its original file: deleting a
    /// user's file outside the store requires an explicit opt-in, which the
    /// command layer does not provide (§20.5).
    ///
    /// The bytes and the registry row move together: files are staged aside,
    /// the registry is written, and only a successful write drops the staged
    /// bytes. A failed write restores every file, so a stored row never points
    /// at a file this call removed.
    pub fn delete_model(id: &str) -> Result<(), String> {
        let _guard = registry_lock();
        let health = Self::registry_health();
        if health.read_only {
            return Err(health.error.unwrap_or_default());
        }
        let mut models = Self::load_registry();
        let Some(index) = models.iter().position(|m| m.id == id) else {
            return Err(format!("Model '{}' not found", id));
        };
        let model = models.remove(index);
        let managed = Self::models_dir();
        // Compare against the canonical root: macOS temp dirs are symlinks
        // and Windows canonical paths carry a `\\?\` prefix.
        let managed_root = managed.canonicalize().unwrap_or_else(|_| managed.clone());
        // Another entry (for example a duplicate imported before per-model
        // directories existed) may still point at the same file.
        let referenced: Vec<String> = models
            .iter()
            .flat_map(|other| other.files.iter())
            .map(|file| Self::comparable_path(&Self::resolve_model_file(file)))
            .collect();

        let trash_dir = managed.join(format!(".trash-{}", uuid::Uuid::new_v4()));
        let mut staged: Vec<(PathBuf, PathBuf)> = Vec::new();
        let mut parents: Vec<PathBuf> = Vec::new();
        for file in &model.files {
            let path = if Path::new(file).is_absolute() {
                PathBuf::from(file)
            } else {
                managed.join(file)
            };
            // Only delete inside the managed tree; never follow a path out.
            match path.canonicalize() {
                Ok(resolved)
                    if resolved.starts_with(&managed_root) || resolved.starts_with(&managed) =>
                {
                    if referenced
                        .iter()
                        .any(|other| other == &Self::comparable_path(&resolved))
                    {
                        continue;
                    }
                    if let Some(parent) = path.parent() {
                        parents.push(parent.to_path_buf());
                    }
                    match stage_removal(&trash_dir, &resolved) {
                        Ok(trashed) => staged.push((resolved, trashed)),
                        Err(error) => {
                            restore_staged(&staged);
                            return Err(error);
                        }
                    }
                }
                _ => {}
            }
        }

        match Self::save_registry(&models) {
            Ok(()) => {
                let _ = fs::remove_dir_all(&trash_dir);
                for parent in parents {
                    let canonical_parent = parent.canonicalize().unwrap_or_else(|_| parent.clone());
                    if canonical_parent != managed_root
                        && (canonical_parent.starts_with(&managed_root)
                            || canonical_parent.starts_with(&managed))
                    {
                        let _ = fs::remove_dir(&parent);
                    }
                }
                Ok(())
            }
            Err(error) => {
                let left_behind = restore_staged(&staged);
                if left_behind == 0 {
                    let _ = fs::remove_dir(&trash_dir);
                    Err(error)
                } else {
                    Err(format!(
                        "{error} {} file(s) could not be restored and are kept in {}.",
                        left_behind,
                        trash_dir.display()
                    ))
                }
            }
        }
    }

    /// Canonical path used to compare two registry file entries. Windows paths
    /// are case-insensitive, so the comparison is too.
    fn comparable_path(path: &Path) -> String {
        let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        let text = resolved.to_string_lossy().to_string();
        #[cfg(windows)]
        {
            text.to_lowercase()
        }
        #[cfg(not(windows))]
        {
            text
        }
    }

    /// Builds the registry row for bytes that are already on disk. Split
    /// imports build the row before the registry is touched, so a failed copy
    /// or write cannot leave a registered model with a partial shard set.
    fn imported_model(
        id: String,
        display_name: String,
        files: Vec<String>,
        file_size: u64,
        metadata: &GgufInfo,
    ) -> LocalModel {
        let hardware = crate::local_ai::hardware::detect_hardware(Some(&Self::models_dir()));
        // Never adopt the model's advertised maximum context (§12.4).
        let working_context = metadata.context_length.clamp(2048, 8192);
        let settings = LocalModelSettings {
            context_length: working_context,
            ..Default::default()
        };
        LocalModel {
            id,
            schema_version: None,
            display_name,
            provider: "Local AI".to_string(),
            source: "import".to_string(),
            repo_id: None,
            revision: None,
            files,
            file_size,
            quantization: metadata.quantization.clone(),
            format: "GGUF".to_string(),
            context_length: metadata.context_length,
            configured_context: working_context,
            backend: hardware.recommended_backend,
            architecture: (!metadata.architecture.is_empty()).then(|| metadata.architecture.clone()),
            gpu_offload: None,
            threads: None,
            runtime_status: ModelRuntimeStatus::Installed,
            capabilities: vec![ModelCapability::Text],
            installed_at: Utc::now().to_rfc3339(),
            updated_at: Utc::now().to_rfc3339(),
            last_used_at: None,
            license: metadata.license.clone(),
            checksum: None,
            user_settings: settings,
        }
    }

    /// Imports one GGUF file into the registry.
    ///
    /// `display_name` overrides the name derived from the file name.
    /// `copy_to_storage` defaults to `true`; `false` registers the file by
    /// reference, which keeps large models on an external disk.
    pub fn import_local_file(
        source: &Path,
        display_name: Option<String>,
        copy_to_storage: Option<bool>,
    ) -> Result<LocalModel, String> {
        if !source.exists() {
            return Err(format!("File not found: {}", source.display()));
        }
        let file_name = source
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| "Invalid file name".to_string())?
            .to_string();

        if !file_name.to_lowercase().ends_with(".gguf") {
            return Err("Selected file is not a GGUF model".to_string());
        }

        // Serialize the whole import: id choice, bytes and registry update must
        // not interleave with the status monitor or another import.
        let _guard = registry_lock();
        // Metadata decides what this file is; the name is only a fallback.
        let metadata = parse_gguf_metadata(source)?;
        let copy = copy_to_storage.unwrap_or(true);
        let health = Self::registry_health();
        if health.read_only {
            return Err(health.error.unwrap_or_default());
        }

        Self::ensure_directories()?;
        let base_name = file_name
            .trim_end_matches(".gguf")
            .trim_end_matches(".GGUF")
            .to_string();
        let shown = display_name.unwrap_or_else(|| base_name.clone());
        // The id is decided before the bytes are written: every model owns a
        // directory derived from it, so equal basenames cannot collide.
        let id = Self::unique_model_id(&base_name);

        let mut created_dir: Option<PathBuf> = None;
        let stored_path: String = if copy {
            let dir = Self::managed_model_dir(&id);
            if !dir.exists() {
                created_dir = Some(dir.clone());
            }
            if let Err(error) = fs::create_dir_all(&dir) {
                if created_dir.is_some() {
                    let _ = fs::remove_dir(&dir);
                }
                return Err(format!("Failed to create the model directory: {}", error));
            }
            let target = dir.join(&file_name);
            let staged = tmp_path(&target);
            let published = fs::copy(source, &staged)
                .map_err(|e| format!("Failed to copy model into storage: {}", e))
                .and_then(|_| {
                    fs::rename(&staged, &target)
                        .map_err(|e| format!("Failed to publish the model file: {}", e))
                });
            if let Err(error) = published {
                // The registry still has no row for these bytes: remove the
                // temp copy and the directory this import created.
                let _ = fs::remove_file(&staged);
                if let Some(dir) = created_dir.as_ref() {
                    let _ = fs::remove_dir(dir);
                }
                return Err(error);
            }
            let folder = dir
                .file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_else(|| "model".to_string());
            format!("{}/{}", folder, file_name)
        } else {
            source.to_string_lossy().to_string()
        };

        let resolved = Self::resolve_model_file(&stored_path);
        let file_size = fs::metadata(&resolved).map(|m| m.len()).unwrap_or(0);

        let model = Self::imported_model(id, shown, vec![stored_path], file_size, &metadata);

        let mut models = Self::load_registry();
        models.retain(|m| m.id != model.id);
        models.push(model.clone());
        // Transaction: a registry write that fails leaves no unpublished model
        // bytes (or an empty per-model directory) behind. Registering by
        // reference publishes nothing, so `resolved` is the user's own file and
        // must never be touched here.
        match Self::save_registry(&models) {
            Ok(()) => Ok(model),
            Err(error) => {
                if copy {
                    let _ = fs::remove_file(&resolved);
                    if let Some(dir) = created_dir {
                        let _ = fs::remove_dir(dir);
                    }
                }
                Err(error)
            }
        }
    }

    /// Parsed name of a split GGUF, e.g. `model-00002-of-00003.gguf`.
    pub fn shard_info(file_name: &str) -> Option<(String, usize, usize)> {
        let lower = file_name.to_lowercase();
        if !lower.ends_with(".gguf") {
            return None;
        }
        let stem = &file_name[..file_name.len() - 5];
        let parts: Vec<&str> = stem.split('-').collect();
        if parts.len() < 4 {
            return None;
        }
        let total: usize = parts[parts.len() - 1].parse().ok()?;
        let of = parts[parts.len() - 2].to_lowercase();
        let index: usize = parts[parts.len() - 3].parse().ok()?;
        if of != "of" || total == 0 || index == 0 {
            return None;
        }
        let base = parts[..parts.len() - 3].join("-");
        if base.is_empty() {
            return None;
        }
        Some((base, index, total))
    }

    /// Proves a split set is complete and every shard is a readable GGUF before
    /// the import writes anything. The first shard supplies the row metadata,
    /// exactly like a single-file import.
    fn validate_split_group(base: &str, files: &[PathBuf]) -> Result<GgufInfo, String> {
        let mut total = 0usize;
        let mut indices = Vec::new();
        for file in files {
            let name = file
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("");
            let Some((_, index, shard_total)) = Self::shard_info(name) else {
                return Err(format!("'{}' is not a split GGUF shard name.", name));
            };
            if total == 0 {
                total = shard_total;
            }
            if shard_total != total {
                return Err(format!(
                    "Split model '{base}' mixes shard sets ({shard_total} shards next to {total})."
                ));
            }
            indices.push(index);
        }
        indices.sort_unstable();
        if indices.is_empty() || indices != (1..=total).collect::<Vec<_>>() {
            return Err(format!(
                "Split model '{base}' is incomplete: found shards {indices:?} of {total}."
            ));
        }
        let mut metadata = None;
        for file in files {
            let parsed = parse_gguf_metadata(file).map_err(|error| {
                format!("Shard '{}' is not a valid GGUF: {}", file.display(), error)
            })?;
            if metadata.is_none() {
                metadata = Some(parsed);
            }
        }
        metadata.ok_or_else(|| format!("Split model '{base}' has no shards."))
    }

    /// Imports every GGUF in a folder. Split models become one entry, so a
    /// three-part model does not show up as three separate models (§8.5).
    pub fn import_folder(path: &Path, copy_to_storage: bool) -> Result<Vec<LocalModel>, String> {
        let entries = fs::read_dir(path).map_err(|e| format!("Failed to read folder: {}", e))?;
        let mut groups: std::collections::BTreeMap<String, Vec<std::path::PathBuf>> =
            std::collections::BTreeMap::new();
        let mut singles: Vec<std::path::PathBuf> = Vec::new();

        for entry in entries.flatten() {
            let file_path = entry.path();
            if !file_path.is_file() {
                continue;
            }
            let name = file_path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if !name.to_lowercase().ends_with(".gguf") {
                continue;
            }
            match Self::shard_info(name) {
                Some((base, _, _)) => groups.entry(base).or_default().push(file_path),
                None => singles.push(file_path),
            }
        }

        if singles.is_empty() && groups.is_empty() {
            return Err("No .gguf files in the selected folder.".to_string());
        }

        let mut imported = Vec::new();
        for file_path in singles {
            imported.push(Self::import_local_file(
                &file_path,
                None,
                Some(copy_to_storage),
            )?);
        }

        for (base, mut files) in groups {
            files.sort_by_key(|p| {
                Self::shard_info(p.file_name().and_then(|n| n.to_str()).unwrap_or(""))
                    .map(|(_, index, _)| index)
                    .unwrap_or(0)
            });
            // Validate the whole set first: an incomplete or unreadable shard
            // must fail before a single byte or row is written.
            let metadata = Self::validate_split_group(&base, &files)?;
            let Some(first) = files.first() else {
                continue;
            };
            let first_stem = first
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("model.gguf")
                .trim_end_matches(".gguf")
                .trim_end_matches(".GGUF")
                .to_string();

            // The lock covers the id choice, the bytes and the row, so another
            // import cannot claim the same directory while the shards are
            // copied. Nothing is registered until every shard is in place.
            let _guard = registry_lock();
            let health = Self::registry_health();
            if health.read_only {
                return Err(health.error.unwrap_or_default());
            }
            let id = Self::unique_model_id(&first_stem);
            let dir = Self::managed_model_dir(&id);
            let created_dir = !dir.exists();

            let (stored_files, created_paths) = if copy_to_storage {
                let folder = dir
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_else(|| "model".to_string());
                let copied = match copy_shards_into(&dir, &files) {
                    Ok(copied) => copied,
                    Err(error) => {
                        if created_dir {
                            let _ = fs::remove_dir(&dir);
                        }
                        return Err(error);
                    }
                };
                let names = files
                    .iter()
                    .filter_map(|file| file.file_name().and_then(|name| name.to_str()))
                    .map(|name| format!("{}/{}", folder, name))
                    .collect::<Vec<_>>();
                (names, copied)
            } else {
                (
                    files
                        .iter()
                        .map(|p| p.to_string_lossy().to_string())
                        .collect(),
                    Vec::new(),
                )
            };

            let file_size = stored_files
                .iter()
                .filter_map(|file| {
                    fs::metadata(Self::resolve_model_file(file))
                        .ok()
                        .map(|meta| meta.len())
                })
                .sum();
            let model = Self::imported_model(id, base, stored_files, file_size, &metadata);
            let mut models = Self::load_registry();
            if let Some(existing) = models.iter_mut().find(|m| m.id == model.id) {
                *existing = model.clone();
            } else {
                models.push(model.clone());
            }
            match Self::save_registry(&models) {
                Ok(()) => imported.push(model),
                Err(error) => {
                    // Only bytes this import wrote go away; the user's folder
                    // and every other model's directory are untouched.
                    for target in &created_paths {
                        let _ = fs::remove_file(target);
                    }
                    if created_dir {
                        let _ = fs::remove_dir(&dir);
                    }
                    return Err(error);
                }
            }
        }

        Ok(imported)
    }

    /// Builds `local/<slug>` and disambiguates collisions with a numeric suffix
    /// so two variants of the same file name never share one API id (§10.1).
    fn unique_model_id(base_name: &str) -> String {
        let existing: Vec<String> = Self::load_registry().into_iter().map(|m| m.id).collect();
        let slug = base_name.to_lowercase().replace([' ', '_'], "-");
        let slug = slug.trim_matches('-').to_string();
        let base = format!("local/{}", if slug.is_empty() { "model" } else { &slug });

        if !existing.iter().any(|id| id == &base) {
            return base;
        }
        let mut counter = 2;
        loop {
            let candidate = format!("{}-{}", base, counter);
            if !existing.iter().any(|id| id == &candidate) {
                return candidate;
            }
            counter += 1;
        }
    }
}

/// Moves one file into the staging directory of a delete. The returned path is
/// what [`restore_staged`] renames back when the registry write fails.
fn stage_removal(trash_dir: &Path, path: &Path) -> Result<PathBuf, String> {
    fs::create_dir_all(trash_dir)
        .map_err(|e| format!("Failed to prepare the delete staging directory: {}", e))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("model.gguf");
    // Unique per file: a split model may repeat a basename across stores and
    // a retry must never overwrite bytes that are already staged.
    let trashed = trash_dir.join(format!("{}-{}", uuid::Uuid::new_v4(), name));
    fs::rename(path, &trashed).map_err(|e| {
        format!(
            "Failed to move {} aside (is the model still in use?): {}",
            path.display(),
            e
        )
    })?;
    Ok(trashed)
}

/// Puts every staged file back in reverse order and returns how many could not
/// be restored. The caller keeps the staging directory when the count is not
/// zero, so the remaining bytes stay recoverable.
fn restore_staged(staged: &[(PathBuf, PathBuf)]) -> usize {
    let mut left_behind = 0;
    for (original, trashed) in staged.iter().rev() {
        if fs::rename(trashed, original).is_err() {
            left_behind += 1;
        }
    }
    left_behind
}

/// Copies every shard into `dir` and returns the paths it wrote. A failure
/// removes the copies it already made, so a half-written split model never
/// survives the call; a shard that already lives at its target is left alone
/// and is not reported as created.
fn copy_shards_into(dir: &Path, files: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    fs::create_dir_all(dir).map_err(|e| format!("Failed to create the model directory: {}", e))?;
    let mut created = Vec::new();
    for file in files {
        let name = file
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| "Invalid shard file name".to_string())?;
        let target = dir.join(name);
        if file == &target {
            continue;
        }
        let staged = tmp_path(&target);
        if let Err(error) = fs::copy(file, &staged) {
            let _ = fs::remove_file(&staged);
            for target in &created {
                let _ = fs::remove_file(target);
            }
            return Err(format!("Failed to copy model shard {}: {}", name, error));
        }
        if let Err(error) = fs::rename(&staged, &target) {
            let _ = fs::remove_file(&staged);
            for target in &created {
                let _ = fs::remove_file(target);
            }
            return Err(format!("Failed to publish model shard {}: {}", name, error));
        }
        created.push(target);
    }
    Ok(created)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shard_names_are_recognised() {
        let parsed = LocalModelStore::shard_info("Qwen3.5-2B-Q4_K_M-00002-of-00003.gguf");
        assert_eq!(parsed, Some(("Qwen3.5-2B-Q4_K_M".to_string(), 2, 3)));
        assert_eq!(LocalModelStore::shard_info("Qwen3.5-2B-BF16.gguf"), None);
        assert_eq!(LocalModelStore::shard_info("my-model-2024.gguf"), None);
    }

    #[test]
    fn model_settings_default_values() {
        let settings = LocalModelSettings::default();
        assert_eq!(settings.context_length, 8192);
        assert_eq!(settings.temperature, 0.7);
        assert!(settings.flash_attention);
    }

    /// Builds a minimal but valid GGUF v3 header and checks that the reader
    /// takes context/depth/architecture from the metadata instead of constants.
    fn write_gguf(path: &Path) {
        use std::io::Write;
        let mut buf: Vec<u8> = Vec::new();
        buf.extend_from_slice(b"GGUF");
        buf.extend_from_slice(&3u32.to_le_bytes()); // version
        buf.extend_from_slice(&0u64.to_le_bytes()); // tensor_count
        buf.extend_from_slice(&7u64.to_le_bytes()); // kv_count

        fn put_string(buf: &mut Vec<u8>, value: &str) {
            buf.extend_from_slice(&(value.len() as u64).to_le_bytes());
            buf.extend_from_slice(value.as_bytes());
        }

        fn put_u32(buf: &mut Vec<u8>, value: u32) {
            buf.extend_from_slice(&4u32.to_le_bytes());
            buf.extend_from_slice(&value.to_le_bytes());
        }

        // general.architecture = "qwen2"
        put_string(&mut buf, "general.architecture");
        buf.extend_from_slice(&8u32.to_le_bytes());
        put_string(&mut buf, "qwen2");

        // qwen2.context_length = 32768
        put_string(&mut buf, "qwen2.context_length");
        put_u32(&mut buf, 32768);

        // qwen2.block_count = 28
        put_string(&mut buf, "qwen2.block_count");
        put_u32(&mut buf, 28);

        // qwen2.attention.head_count = 28
        put_string(&mut buf, "qwen2.attention.head_count");
        put_u32(&mut buf, 28);

        // qwen2.attention.head_count_kv = 4 (GQA)
        put_string(&mut buf, "qwen2.attention.head_count_kv");
        put_u32(&mut buf, 4);

        // qwen2.embedding_length = 3584 → head_dim 128
        put_string(&mut buf, "qwen2.embedding_length");
        put_u32(&mut buf, 3584);

        // general.file_type = 15 (Q4_K_M)
        put_string(&mut buf, "general.file_type");
        put_u32(&mut buf, 15);

        let mut file = fs::File::create(path).unwrap();
        file.write_all(&buf).unwrap();
    }

    #[test]
    fn gguf_parser_reads_metadata_instead_of_constants() {
        let dir = std::env::temp_dir().join(format!("melon-gguf-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("model-NAME-LIES-Q8_0.gguf");
        write_gguf(&path);

        let info = parse_gguf_metadata(&path).expect("metadata");
        assert_eq!(info.architecture, "qwen2");
        assert_eq!(info.context_length, 32768);
        assert_eq!(info.block_count, 28);
        assert_eq!(info.effective_layer_count(), 28);
        // From general.file_type, not from the misleading file name.
        assert_eq!(info.quantization, "Q4_K_M");

        // GQA geometry: 28 query heads, 4 K/V heads, 128-wide head.
        assert_eq!(info.head_count, 28);
        assert_eq!(info.head_count_kv, 4);
        assert_eq!(
            info.kv_geometry(),
            Some(crate::local_ai::hardware::KvGeometry {
                layers: 28,
                kv_heads: 4,
                head_dim: 128,
            })
        );

        let _ = fs::remove_file(&path);
        let _ = fs::remove_dir(&dir);
    }

    #[test]
    fn gguf_without_head_geometry_returns_none_instead_of_guessing() {
        let dir = std::env::temp_dir().join(format!("melon-gguf-nogeom-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("plain.gguf");
        {
            let mut buf: Vec<u8> = Vec::new();
            buf.extend_from_slice(b"GGUF");
            buf.extend_from_slice(&3u32.to_le_bytes());
            buf.extend_from_slice(&0u64.to_le_bytes());
            buf.extend_from_slice(&1u64.to_le_bytes());
            buf.extend_from_slice(&(17u64).to_le_bytes());
            buf.extend_from_slice(b"qwen2.block_count");
            buf.extend_from_slice(&4u32.to_le_bytes());
            buf.extend_from_slice(&28u32.to_le_bytes());
            fs::write(&path, &buf).unwrap();
        }

        let info = parse_gguf_metadata(&path).expect("metadata");
        assert_eq!(info.block_count, 28);
        assert_eq!(info.kv_geometry(), None);

        let _ = fs::remove_file(&path);
        let _ = fs::remove_dir(&dir);
    }

    #[test]
    fn settings_profile_uses_one_snake_case_wire_spelling() {
        // The UI sends exactly these strings.
        for (value, expected) in [
            ("auto", ModelConfigProfile::Auto),
            ("performance", ModelConfigProfile::Performance),
            ("balanced", ModelConfigProfile::Balanced),
            ("memory_saver", ModelConfigProfile::MemorySaver),
            ("custom", ModelConfigProfile::Custom),
        ] {
            let parsed: ModelConfigProfile =
                serde_json::from_value(serde_json::json!(value)).expect(value);
            assert_eq!(parsed, expected);
        }

        // Serialization is the same vocabulary, never `MemorySaver`.
        assert_eq!(
            serde_json::to_value(ModelConfigProfile::MemorySaver).unwrap(),
            serde_json::json!("memory_saver")
        );

        // Old spellings keep decoding instead of failing the save.
        for (legacy, expected) in [
            ("Auto", ModelConfigProfile::Auto),
            ("Performance", ModelConfigProfile::Performance),
            ("Balanced", ModelConfigProfile::Balanced),
            ("Memory Saver", ModelConfigProfile::MemorySaver),
            ("low_memory", ModelConfigProfile::MemorySaver),
            ("speed", ModelConfigProfile::Performance),
            ("quality", ModelConfigProfile::Balanced),
            ("Custom", ModelConfigProfile::Custom),
        ] {
            let parsed: ModelConfigProfile =
                serde_json::from_value(serde_json::json!(legacy)).expect(legacy);
            assert_eq!(parsed, expected);
        }
    }

    #[test]
    fn a_patch_keeps_fields_the_dialog_does_not_edit() {
        let mut stored = LocalModelSettings {
            top_k: 17,
            repeat_penalty: 1.25,
            batch_size: 256,
            chat_template: Some("custom-template".to_string()),
            seed: Some(4242),
            reasoning_enabled: Some(true),
            ..LocalModelSettings::default()
        };

        let patch: LocalModelSettingsPatch = serde_json::from_value(serde_json::json!({
            "profile": "performance",
            "contextLength": 16384,
            "temperature": 0.0,
            "topP": 0.0,
        }))
        .unwrap();
        stored.apply_patch(patch).unwrap();

        // Edits landed, including zero (the old `||` made it 0.7 again).
        assert_eq!(stored.profile, ModelConfigProfile::Performance);
        assert_eq!(stored.context_length, 16384);
        assert_eq!(stored.temperature, 0.0);
        assert_eq!(stored.top_p, 0.0);
        // Everything else survived.
        assert_eq!(stored.top_k, 17);
        assert_eq!(stored.repeat_penalty, 1.25);
        assert_eq!(stored.batch_size, 256);
        assert_eq!(stored.chat_template.as_deref(), Some("custom-template"));
        assert_eq!(stored.seed, Some(4242));
        assert!(stored.is_reasoning_on());
    }

    #[test]
    fn patch_can_set_chat_template_reasoning_and_seed() {
        let mut stored = LocalModelSettings::default();
        let patch: LocalModelSettingsPatch = serde_json::from_value(serde_json::json!({
            "chatTemplate": "{{ .Prompt }}",
            "reasoningEnabled": true,
            "seed": 0,
        }))
        .unwrap();
        stored.apply_patch(patch).unwrap();

        assert_eq!(stored.chat_template.as_deref(), Some("{{ .Prompt }}"));
        assert!(stored.is_reasoning_on());
        // Seed 0 is a seed, not "no seed".
        assert_eq!(stored.seed, Some(0));

        // The audit spells the flag `reasoning`; both names are accepted.
        let legacy: LocalModelSettingsPatch =
            serde_json::from_value(serde_json::json!({ "reasoning": true })).unwrap();
        assert_eq!(legacy.reasoning_enabled, Some(true));
    }

    #[test]
    fn numeric_validation_keeps_zero_but_rejects_impossible_values() {
        let mut settings = LocalModelSettings::default();
        // 0 is valid for sampling knobs and seeds.
        let zero: LocalModelSettingsPatch = serde_json::from_value(serde_json::json!({
            "temperature": 0,
            "topP": 0,
            "topK": 0,
            "repeatPenalty": 0,
            "seed": 0,
        }))
        .unwrap();
        settings.apply_patch(zero).unwrap();
        assert_eq!(settings.temperature, 0.0);
        assert_eq!(settings.top_p, 0.0);
        assert_eq!(settings.top_k, 0);
        assert_eq!(settings.repeat_penalty, 0.0);
        assert_eq!(settings.seed, Some(0));

        assert!(serde_json::from_value::<LocalModelSettingsPatch>(
            serde_json::json!({ "temperature": "hot" })
        )
        .is_err());

        for (field, value) in [
            ("temperature", serde_json::json!(2.5)),
            ("topP", serde_json::json!(1.5)),
            ("repeatPenalty", serde_json::json!(-1.0)),
            ("contextLength", serde_json::json!(0)),
            ("contextLength", serde_json::json!(100)),
            ("batchSize", serde_json::json!(0)),
        ] {
            let patch: LocalModelSettingsPatch =
                serde_json::from_value(serde_json::json!({ field: value })).unwrap();
            let mut candidate = LocalModelSettings::default();
            assert!(
                candidate.apply_patch(patch).is_err(),
                "{} = {} should be rejected",
                field,
                value
            );
        }
    }

    #[test]
    fn gguf_parser_rejects_foreign_files() {
        let dir = std::env::temp_dir().join(format!("melon-gguf-bad-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("nope.gguf");
        fs::write(&path, b"NOTG").unwrap();

        assert!(parse_gguf_metadata(&path).is_err());

        let _ = fs::remove_file(&path);
        let _ = fs::remove_dir(&dir);
    }
    fn temp_root(tag: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "melon-local-models-{}-{}-{}",
            tag,
            std::process::id(),
            nanos
        ));
        fs::create_dir_all(root.join("metadata")).unwrap();
        root
    }

    fn append_marker(path: &Path, marker: &[u8]) {
        use std::io::Write;
        let mut file = fs::OpenOptions::new().append(true).open(path).unwrap();
        file.write_all(marker).unwrap();
    }

    fn demo_model(id: &str, files: Vec<String>) -> LocalModel {
        LocalModel {
            id: id.to_string(),
            schema_version: None,
            display_name: id.to_string(),
            provider: "Local AI".to_string(),
            source: "import".to_string(),
            repo_id: None,
            revision: None,
            files,
            file_size: 16,
            quantization: "Q4_K_M".to_string(),
            format: "GGUF".to_string(),
            context_length: 4096,
            configured_context: 4096,
            backend: InferenceBackend::Cpu,
            gpu_offload: None,
            threads: None,
            runtime_status: ModelRuntimeStatus::Installed,
            capabilities: vec![ModelCapability::Text],
            installed_at: "2026-01-01T00:00:00Z".to_string(),
            updated_at: "2026-01-01T00:00:00Z".to_string(),
            last_used_at: None,
            license: None,
            checksum: None,
            architecture: None,
            user_settings: LocalModelSettings::default(),
        }
    }

    #[test]
    fn equal_basenames_import_into_separate_directories_and_survive_delete() {
        let root = temp_root("collision");
        with_test_root(&root, || {
            let source_a = root.join("a");
            let source_b = root.join("b");
            fs::create_dir_all(&source_a).unwrap();
            fs::create_dir_all(&source_b).unwrap();
            let file_a = source_a.join("weights.gguf");
            let file_b = source_b.join("weights.gguf");
            write_gguf(&file_a);
            append_marker(&file_a, b"A");
            write_gguf(&file_b);
            append_marker(&file_b, b"B");

            let first = LocalModelStore::import_local_file(&file_a, None, Some(true)).unwrap();
            let second = LocalModelStore::import_local_file(&file_b, None, Some(true)).unwrap();
            assert_ne!(first.id, second.id, "ids must stay unique");
            assert_ne!(first.files, second.files, "two models share one file");
            let path_a = LocalModelStore::resolve_model_file(&first.files[0]);
            let path_b = LocalModelStore::resolve_model_file(&second.files[0]);
            assert!(path_a.exists() && path_b.exists());

            // Deleting B must not touch A's bytes or record.
            LocalModelStore::delete_model(&second.id).unwrap();
            assert!(
                path_a.exists(),
                "deleting one model removed the other's file"
            );
            let remaining = LocalModelStore::get_model(&first.id).expect("A still registered");
            assert_eq!(remaining.files, first.files);
            assert_eq!(fs::read(&path_a).unwrap().last(), Some(&b'A'));
            assert!(!path_b.exists());
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn deleting_one_of_two_records_sharing_a_file_keeps_the_file() {
        let root = temp_root("shared-delete");
        with_test_root(&root, || {
            let dir = LocalModelStore::models_dir().join("shared");
            fs::create_dir_all(&dir).unwrap();
            let shared = dir.join("shared.gguf");
            write_gguf(&shared);
            let relative = "shared/shared.gguf".to_string();
            let first = demo_model("local/first", vec![relative.clone()]);
            let second = demo_model("local/second", vec![relative.clone()]);
            LocalModelStore::save_registry(&[first.clone(), second.clone()]).unwrap();

            LocalModelStore::delete_model(&first.id).unwrap();
            assert!(
                shared.exists(),
                "a shared file was deleted with one reference"
            );
            assert!(LocalModelStore::get_model(&second.id).is_some());

            LocalModelStore::delete_model(&second.id).unwrap();
            assert!(!shared.exists(), "the last reference must remove the file");
            assert!(!dir.exists(), "the empty per-model directory is removed");
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_registry_row_from_a_newer_build_is_visible_but_read_only() {
        let root = temp_root("newer-row");
        with_test_root(&root, || {
            let dir = root.join("models").join("managed");
            fs::create_dir_all(&dir).unwrap();
            let file = dir.join("model.gguf");
            write_gguf(&file);
            let newer = serde_json::json!([{
                "id": "local/newer",
                "schemaVersion": crate::schema::CURRENT + 1,
                "displayName": "Newer",
                "provider": "Local AI",
                "source": "import",
                "files": ["managed/model.gguf"],
                "fileSize": 16,
                "quantization": "Q4_K_M",
                "format": "GGUF",
                "contextLength": 4096,
                "configuredContext": 4096,
                "backend": "CPU",
                "runtimeStatus": "installed",
                "capabilities": ["text"],
                "installedAt": "2026-01-01T00:00:00Z",
                "updatedAt": "2026-01-01T00:00:00Z",
            }]);
            fs::write(root.join("metadata").join("models.json"), newer.to_string()).unwrap();

            // The row still renders, but nothing may rewrite the file.
            assert_eq!(LocalModelStore::load_registry().len(), 1);
            let health = LocalModelStore::registry_health();
            assert!(health.read_only);
            assert!(health.error.as_deref().unwrap_or("").contains("newer"));
            assert!(LocalModelStore::save_registry(&[]).is_err());
            assert!(LocalModelStore::recover_registry().is_err());
            let on_disk = fs::read_to_string(root.join("metadata").join("models.json")).unwrap();
            assert!(on_disk.contains("local/newer"));
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn upsert_keeps_rows_written_by_other_code_paths() {
        let root = temp_root("upsert");
        with_test_root(&root, || {
            let first = demo_model("local/first", vec!["missing-a.gguf".to_string()]);
            let second = demo_model("local/second", vec!["missing-b.gguf".to_string()]);
            LocalModelStore::upsert_model(&first).unwrap();
            LocalModelStore::upsert_model(&second).unwrap();
            let models = LocalModelStore::load_registry();
            assert_eq!(models.len(), 2);
            assert_eq!(models[0].schema_version, Some(crate::schema::CURRENT));
            assert_eq!(models[1].schema_version, Some(crate::schema::CURRENT));
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn corrupt_registry_is_read_only_visible_and_backed_up() {
        let root = temp_root("corrupt");
        with_test_root(&root, || {
            let path = root.join("metadata").join("models.json");
            fs::write(&path, b"{ definitely not a registry").unwrap();

            assert!(LocalModelStore::load_registry().is_empty());
            let health = LocalModelStore::registry_health();
            assert!(health.read_only, "a damaged registry must be read-only");
            assert!(health.error.as_deref().unwrap_or("").contains("damaged"));
            let backup = root.join("metadata").join("models.corrupt.bak");
            assert!(backup.exists(), "the damaged file must be backed up");
            assert_eq!(health.backup_path.as_deref(), backup.to_str());

            // A write neither succeeds nor overwrites the damaged source.
            assert!(LocalModelStore::save_registry(&[]).is_err());
            assert_eq!(
                fs::read_to_string(&path).unwrap(),
                "{ definitely not a registry"
            );

            // Import is refused before any bytes are copied.
            let source = root.join("incoming.gguf");
            write_gguf(&source);
            assert!(LocalModelStore::import_local_file(&source, None, Some(true)).is_err());
            assert!(!LocalModelStore::models_dir().join("incoming.gguf").exists());

            // Explicit recovery keeps the backup and starts an empty library.
            LocalModelStore::recover_registry().unwrap();
            assert!(!LocalModelStore::registry_health().read_only);
            assert!(backup.exists());
            assert!(LocalModelStore::load_registry().is_empty());
            LocalModelStore::save_registry(&[]).unwrap();
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_second_corruption_keeps_the_first_revision_recoverable() {
        let root = temp_root("corrupt-twice");
        with_test_root(&root, || {
            let metadata = root.join("metadata");
            let path = metadata.join("models.json");
            let first = metadata.join("models.corrupt.bak");
            let second = metadata.join("models.corrupt.1.bak");
            fs::create_dir_all(&metadata).unwrap();
            fs::write(&path, b"{ first damage").unwrap();
            assert!(LocalModelStore::load_registry().is_empty());
            LocalModelStore::recover_registry().unwrap();
            assert_eq!(fs::read_to_string(&first).unwrap(), "{ first damage");

            // A later corruption must not delete the newer damaged bytes just
            // because the first backup already exists.
            fs::write(&path, b"{ second damage").unwrap();
            assert!(LocalModelStore::load_registry().is_empty());
            let health = LocalModelStore::registry_health();
            assert_eq!(health.backup_path.as_deref(), second.to_str());
            assert_eq!(fs::read_to_string(&first).unwrap(), "{ first damage");
            assert_eq!(fs::read_to_string(&second).unwrap(), "{ second damage");

            // Recovery reuses the backup it just wrote instead of producing
            // yet another copy.
            LocalModelStore::recover_registry().unwrap();
            assert!(!metadata.join("models.corrupt.2.bak").exists());
            assert_eq!(fs::read_to_string(&first).unwrap(), "{ first damage");
            assert_eq!(fs::read_to_string(&second).unwrap(), "{ second damage");
            assert!(LocalModelStore::load_registry().is_empty());
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn quarantine_reuses_a_read_only_rescue_without_rewriting() {
        let root = temp_root("corrupt-readonly-rescue");
        fs::create_dir_all(&root).unwrap();
        let path = root.join("models.json");
        let backup = LocalModelStore::quarantine_registry(&path, "{ damaged").unwrap();
        let permissions = fs::metadata(&backup).unwrap().permissions();
        let mut read_only = permissions.clone();
        read_only.set_readonly(true);
        fs::set_permissions(&backup, read_only).unwrap();

        let reused = LocalModelStore::quarantine_registry(&path, "{ damaged");
        fs::set_permissions(&backup, permissions).unwrap();
        assert_eq!(reused.as_ref(), Some(&backup));
        assert_eq!(fs::read(&backup).unwrap(), b"{ damaged");
        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn quarantine_skips_a_dangling_backup_symlink() {
        let root = temp_root("corrupt-backup-symlink");
        fs::create_dir_all(&root).unwrap();
        let path = root.join("models.json");
        let missing = root.join("missing-rescue-target");
        let reserved = root.join("models.corrupt.bak");
        std::os::unix::fs::symlink(&missing, &reserved).unwrap();

        let backup = LocalModelStore::quarantine_registry(&path, "{ damaged").unwrap();
        assert_eq!(backup, root.join("models.corrupt.1.bak"));
        assert_eq!(fs::read(&backup).unwrap(), b"{ damaged");
        assert!(fs::symlink_metadata(&reserved)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!missing.exists());
        let _ = fs::remove_dir_all(&root);
    }

    fn staging_directories(root: &Path) -> Vec<PathBuf> {
        let Ok(entries) = fs::read_dir(root.join("models")) else {
            return Vec::new();
        };
        entries
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .map(|name| name.to_string_lossy().starts_with(".trash-"))
                    .unwrap_or(false)
            })
            .collect()
    }

    #[test]
    fn a_failed_publish_leaves_no_staged_bytes() {
        let root = temp_root("import-rename");
        with_test_root(&root, || {
            let source = root.join("weights.gguf");
            write_gguf(&source);
            // Occupy the final name with a directory so the publish rename
            // fails after the copy into the staging path already succeeded.
            let id = LocalModelStore::unique_model_id("weights");
            let dir = LocalModelStore::managed_model_dir(&id);
            fs::create_dir_all(&dir).unwrap();
            fs::create_dir(dir.join("weights.gguf")).unwrap();

            assert!(LocalModelStore::import_local_file(&source, None, Some(true)).is_err());
            let leftovers: Vec<String> = fs::read_dir(&dir)
                .unwrap()
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.file_name().to_string_lossy().to_string())
                .collect();
            assert_eq!(
                leftovers,
                vec!["weights.gguf".to_string()],
                "a failed publish left staged bytes behind"
            );
            assert!(LocalModelStore::load_registry().is_empty());
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_failed_registry_write_restores_the_deleted_files() {
        let root = temp_root("delete-rollback");
        with_test_root(&root, || {
            let dir = LocalModelStore::models_dir().join("managed");
            fs::create_dir_all(&dir).unwrap();
            let file = dir.join("model.gguf");
            write_gguf(&file);
            append_marker(&file, b"keep these bytes");
            let bytes = fs::read(&file).unwrap();
            let model = demo_model("local/rollback", vec!["managed/model.gguf".to_string()]);
            LocalModelStore::save_registry(std::slice::from_ref(&model)).unwrap();

            fail_next_registry_save();
            let error = LocalModelStore::delete_model(&model.id).expect_err("the write must fail");
            assert!(error.contains("injected"), "unexpected error: {error}");

            // The row still exists and every byte it points at is back.
            assert_eq!(fs::read(&file).unwrap(), bytes);
            assert!(LocalModelStore::get_model(&model.id).is_some());
            assert!(
                staging_directories(&root).is_empty(),
                "a rolled back delete left staged bytes behind"
            );
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_by_reference_import_keeps_the_user_file_when_the_registry_write_fails() {
        let root = temp_root("reference-rollback");
        with_test_root(&root, || {
            let external = root.join("external");
            fs::create_dir_all(&external).unwrap();
            let source = external.join("weights.gguf");
            write_gguf(&source);
            let bytes = fs::read(&source).unwrap();

            fail_next_registry_save();
            let error = LocalModelStore::import_local_file(&source, None, Some(false))
                .expect_err("the write must fail");
            assert!(error.contains("injected"), "unexpected error: {error}");

            // Registering by reference publishes no bytes: the user's file is
            // not ours to remove when the row cannot be written.
            assert_eq!(fs::read(&source).unwrap(), bytes);
            assert!(LocalModelStore::load_registry().is_empty());
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_copied_import_rolls_back_its_bytes_when_the_registry_write_fails() {
        let root = temp_root("copy-rollback");
        with_test_root(&root, || {
            let external = root.join("external");
            fs::create_dir_all(&external).unwrap();
            let source = external.join("weights.gguf");
            write_gguf(&source);
            let bytes = fs::read(&source).unwrap();

            fail_next_registry_save();
            let error = LocalModelStore::import_local_file(&source, None, Some(true))
                .expect_err("the write must fail");
            assert!(error.contains("injected"), "unexpected error: {error}");

            assert_eq!(fs::read(&source).unwrap(), bytes, "the source was removed");
            assert!(LocalModelStore::load_registry().is_empty());
            // The copied file and its per-model directory are gone too.
            assert!(fs::read_dir(LocalModelStore::models_dir())
                .unwrap()
                .next()
                .is_none());
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_incomplete_split_set_is_rejected_before_anything_is_written() {
        let root = temp_root("split-incomplete");
        with_test_root(&root, || {
            let folder = root.join("incoming");
            fs::create_dir_all(&folder).unwrap();
            write_gguf(&folder.join("qwen-00001-of-00003.gguf"));
            write_gguf(&folder.join("qwen-00003-of-00003.gguf"));
            let bytes = fs::read(folder.join("qwen-00001-of-00003.gguf")).unwrap();

            let error = LocalModelStore::import_folder(&folder, true)
                .expect_err("an incomplete set must be refused");
            assert!(error.contains("incomplete"), "unexpected error: {error}");

            // No row, no managed directory, and the user's shards are intact.
            assert!(LocalModelStore::load_registry().is_empty());
            assert!(!LocalModelStore::models_dir().exists());
            assert_eq!(
                fs::read(folder.join("qwen-00001-of-00003.gguf")).unwrap(),
                bytes
            );
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_split_set_with_an_unreadable_shard_is_rejected_up_front() {
        let root = temp_root("split-bad-shard");
        with_test_root(&root, || {
            let folder = root.join("incoming");
            fs::create_dir_all(&folder).unwrap();
            write_gguf(&folder.join("qwen-00001-of-00002.gguf"));
            fs::write(
                folder.join("qwen-00002-of-00002.gguf"),
                b"<html>not a model</html>",
            )
            .unwrap();

            let error = LocalModelStore::import_folder(&folder, true)
                .expect_err("a corrupt shard must be refused");
            assert!(
                error.contains("not a valid GGUF"),
                "unexpected error: {error}"
            );

            assert!(LocalModelStore::load_registry().is_empty());
            assert!(!LocalModelStore::models_dir().exists());
        });
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_split_import_rolls_back_its_own_bytes_when_the_registry_write_fails() {
        let root = temp_root("split-rollback");
        with_test_root(&root, || {
            let folder = root.join("incoming");
            fs::create_dir_all(&folder).unwrap();
            let first = folder.join("qwen-00001-of-00002.gguf");
            let second = folder.join("qwen-00002-of-00002.gguf");
            write_gguf(&first);
            append_marker(&first, b"one");
            write_gguf(&second);
            append_marker(&second, b"two");
            let first_bytes = fs::read(&first).unwrap();
            let second_bytes = fs::read(&second).unwrap();

            fail_next_registry_save();
            let error = LocalModelStore::import_folder(&folder, true)
                .expect_err("the registry write must fail");
            assert!(error.contains("injected"), "unexpected error: {error}");

            // The user's folder is untouched and no managed copy survives.
            assert_eq!(fs::read(&first).unwrap(), first_bytes);
            assert_eq!(fs::read(&second).unwrap(), second_bytes);
            assert!(LocalModelStore::load_registry().is_empty());
            assert!(fs::read_dir(LocalModelStore::models_dir())
                .unwrap()
                .next()
                .is_none());
        });
        let _ = fs::remove_dir_all(&root);
    }
}
