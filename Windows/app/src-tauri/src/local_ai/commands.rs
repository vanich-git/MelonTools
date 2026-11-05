//! Tauri IPC commands for Local AI.

use serde::Deserialize;
use std::path::{Path, PathBuf};
use tauri::State;

use super::hardware::{
    calculate_memory_estimation, detect_hardware, HardwareInfo, KvGeometry, MemoryEstimation,
};
use super::huggingface::{HFModelDetails, HFModelSearchResult, HuggingFaceService};
use super::local_models::{LocalModel, LocalModelSettingsPatch, LocalModelStore, RegistryHealth};
use super::local_runtime::{
    RuntimeInstallStatus, RuntimeMetrics, RuntimeStatusPayload, DEFAULT_LOG_LINES,
};
use super::migration::{last_report, MigrationReport};
use super::model_downloads::DownloadProgress;
use super::runtime_catalog::{fetch_catalog, RuntimeCatalogRelease};
use crate::AppState;

#[tauri::command]
pub async fn local_ai_hardware_info() -> Result<HardwareInfo, String> {
    let models_dir = LocalModelStore::models_dir();
    Ok(detect_hardware(Some(&models_dir)))
}

#[tauri::command]
pub async fn local_ai_models_list() -> Result<Vec<LocalModel>, String> {
    Ok(LocalModelStore::load_registry())
}

/// Read-only state of `models.json`. A damaged registry is reported to the UI
/// instead of silently looking like an empty library.
#[tauri::command]
pub fn local_ai_registry_health() -> RegistryHealth {
    LocalModelStore::registry_health()
}

/// Explicit recovery: keep the damaged file as `models.corrupt.bak` and start
/// a new empty library. Until this is called every write is refused.
#[tauri::command]
pub fn local_ai_registry_recover() -> Result<RegistryHealth, String> {
    LocalModelStore::recover_registry()?;
    Ok(LocalModelStore::registry_health())
}

#[tauri::command]
pub async fn local_ai_model_get(id: String) -> Result<LocalModel, String> {
    LocalModelStore::get_model(&id).ok_or_else(|| format!("Model '{}' not found", id))
}

/// Partial update: the renderer sends only the fields the dialog edits, and
/// the backend merges them over what is stored. A full settings object is
/// still accepted (every field present), so the contract stays compatible.
#[tauri::command]
pub async fn local_ai_model_save_settings(
    id: String,
    settings: LocalModelSettingsPatch,
) -> Result<LocalModel, String> {
    LocalModelStore::update_model_settings(&id, settings)
}

/// Rewrites `config.yaml` when the runtime moved since the last write. The
/// engine hot-reloads the file, so the gateway catalogue cannot keep
/// advertising a model that stopped, crashed or was unloaded.
pub fn sync_gateway_after_transition(state: &AppState) {
    let Some(revision) = state.local_runtime.pending_gateway_revision() else {
        return;
    };
    let settings = state.settings();
    if crate::gateway::write_config(&settings).is_ok() {
        state.local_runtime.mark_gateway_synced(revision);
    }
}

#[tauri::command]
pub async fn local_ai_model_delete(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let status = state.local_runtime.get_status();
    if status.is_running && status.model_id.as_deref() == Some(&id) {
        state.local_runtime.stop().await;
    }
    let result = LocalModelStore::delete_model(&id);
    sync_gateway_after_transition(&state);
    result
}

#[tauri::command]
pub async fn local_ai_runtime_status(
    state: State<'_, AppState>,
) -> Result<RuntimeStatusPayload, String> {
    // `get_status` also reaps a crashed engine and normalizes impossible
    // states, so this poll is where a crash becomes a gateway rewrite.
    let status = state.local_runtime.get_status();
    sync_gateway_after_transition(&state);
    Ok(status)
}

/// The one-time 5.5.5 -> 6.0.0 backup report. `None` only before startup has
/// run it; the UI shows `error` when a copy or marker failed.
#[tauri::command]
pub fn local_ai_migration_report() -> Option<MigrationReport> {
    last_report()
}

/// Live counters from the running engine. The desktop UI polls this only
/// while the Local AI runtime tab is visible and the engine is running.
#[tauri::command]
pub async fn local_ai_runtime_metrics(
    state: State<'_, AppState>,
) -> Result<RuntimeMetrics, String> {
    state.local_runtime.metrics().await
}

/// Tail of the engine log for the Console pane. The UI polls this while the
/// Runtime tab is visible; the read is capped so a huge log cannot stall IPC.
#[tauri::command]
pub fn local_ai_runtime_logs(
    state: State<'_, AppState>,
    max_lines: Option<usize>,
) -> Result<Vec<String>, String> {
    state
        .local_runtime
        .logs(max_lines.unwrap_or(DEFAULT_LOG_LINES))
}

/// Hides the Console output without touching the engine's log file.
#[tauri::command]
pub fn local_ai_runtime_logs_clear(state: State<'_, AppState>) -> Result<(), String> {
    state.local_runtime.clear_logs()
}

#[tauri::command]
pub async fn local_ai_start_model(state: State<'_, AppState>, id: String) -> Result<(), String> {
    // The manager claims the lifecycle generation before it reads the model,
    // so a stop that raced ahead of this command wins instead of being
    // overwritten by a launch whose model lookup started earlier.
    let result = state.local_runtime.load_model(&id).await;
    // Ready or Failed, the gateway catalogue has to follow the transition.
    sync_gateway_after_transition(&state);
    result
}

#[tauri::command]
pub async fn local_ai_stop_runtime(state: State<'_, AppState>) -> Result<(), String> {
    state.local_runtime.stop().await;
    sync_gateway_after_transition(&state);
    Ok(())
}

/// Lists official llama.cpp Windows builds. Read-only: nothing is written to
/// disk and the install itself still starts through `local_ai_runtime_install`.
#[tauri::command]
pub async fn local_ai_runtime_catalog() -> Result<Vec<RuntimeCatalogRelease>, String> {
    fetch_catalog().await
}

/// Downloads and validates a ZIP runtime package in the background. The
/// caller must supply the archive SHA-256; an install never replaces the
/// running engine or a published package.
#[tauri::command]
pub fn local_ai_runtime_install(
    state: State<'_, AppState>,
    url: String,
    sha256: String,
) -> Result<String, String> {
    state.local_runtime.start_install(&url, &sha256)
}

#[tauri::command]
pub fn local_ai_runtime_install_status(state: State<'_, AppState>) -> RuntimeInstallStatus {
    state.local_runtime.install_status()
}

#[tauri::command]
pub fn local_ai_runtime_install_cancel(state: State<'_, AppState>) -> Result<(), String> {
    state.local_runtime.cancel_install();
    Ok(())
}

#[tauri::command]
pub async fn local_ai_set_binary_path(
    state: State<'_, AppState>,
    path: Option<String>,
) -> Result<(), String> {
    let pb = path.map(PathBuf::from);
    state.local_runtime.set_custom_binary_path(pb);
    Ok(())
}

/// Uses the explicit token when the caller has one, otherwise the stored one.
/// The UI no longer holds the secret, so `None` is the normal case.
fn resolve_hf_token(token: Option<String>) -> Option<String> {
    token
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .or_else(crate::local_ai::secret_store::load_hf_token)
}

#[tauri::command]
pub async fn local_ai_hf_search(
    query: String,
    limit: Option<usize>,
    token: Option<String>,
) -> Result<Vec<HFModelSearchResult>, String> {
    let token = resolve_hf_token(token);
    HuggingFaceService::search_models(&query, limit.unwrap_or(20), token.as_deref()).await
}

#[tauri::command]
pub async fn local_ai_hf_model_details(
    repo_id: String,
    token: Option<String>,
) -> Result<HFModelDetails, String> {
    let token = resolve_hf_token(token);
    HuggingFaceService::get_model_details(&repo_id, token.as_deref()).await
}

/// One typed request for a model download. The renderer used to pass the
/// LFS SHA-256 as a sixth positional argument that the JS shim dropped, so the
/// backend could never verify a published digest.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadRequest {
    pub repo_id: String,
    pub filename: String,
    pub download_url: String,
    #[serde(default)]
    pub quantization: String,
    /// Explicit token from the caller; `None` means "use the stored one".
    #[serde(default)]
    pub token: Option<String>,
    /// `lfs.sha256` from the Hugging Face API, when published.
    #[serde(default)]
    pub sha256: Option<String>,
}

#[tauri::command]
pub async fn local_ai_download_start(
    state: State<'_, AppState>,
    request: DownloadRequest,
) -> Result<String, String> {
    // A download needs the same stored token search/details use; asking the
    // renderer for it was the reason gated repos failed to download.
    let token = resolve_hf_token(request.token);
    let quantization = if request.quantization.trim().is_empty() {
        "GGUF".to_string()
    } else {
        request.quantization
    };
    state
        .download_manager
        .start_download(
            request.repo_id,
            request.filename,
            request.download_url,
            quantization,
            token,
            request.sha256,
        )
        .await
}

#[tauri::command]
pub async fn local_ai_download_cancel(
    state: State<'_, AppState>,
    model_id: String,
) -> Result<(), String> {
    state.download_manager.cancel_download(&model_id);
    Ok(())
}

#[tauri::command]
pub async fn local_ai_downloads_list(
    state: State<'_, AppState>,
) -> Result<Vec<DownloadProgress>, String> {
    Ok(state.download_manager.get_all_downloads())
}

/// Removes finished rows for real. The UI used to filter its own array, and
/// the next poll restored every completed download.
#[tauri::command]
pub fn local_ai_downloads_clear(state: State<'_, AppState>) -> Result<usize, String> {
    Ok(state.download_manager.clear_finished())
}

#[tauri::command]
pub async fn local_ai_import_file(path: String) -> Result<LocalModel, String> {
    LocalModelStore::import_local_file(Path::new(&path), None, None)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EstimateMemoryParams {
    pub weights_size: u64,
    pub context_length: usize,
    #[serde(default = "default_kv_cache_type")]
    pub kv_cache_type: String,
    #[serde(default = "default_batch_size")]
    pub batch_size: usize,
    /// Installed model whose GGUF header supplies the real layer/head
    /// geometry. Without it (or when the header omits it) the estimator
    /// reports `confidence: heuristic`.
    #[serde(default)]
    pub model_id: Option<String>,
    /// Explicit geometry, used when no installed model is named.
    #[serde(default)]
    pub total_layers: Option<usize>,
    #[serde(default)]
    pub kv_heads: Option<usize>,
    #[serde(default)]
    pub head_dim: Option<usize>,
}

fn default_kv_cache_type() -> String {
    "f16".to_string()
}

fn default_batch_size() -> usize {
    512
}

fn estimation_geometry(params: &EstimateMemoryParams) -> Option<KvGeometry> {
    if let Some(id) = params.model_id.as_deref() {
        if let Some(model) = LocalModelStore::get_model(id) {
            if let Some(geometry) = LocalModelStore::model_kv_geometry(&model) {
                return Some(geometry);
            }
        }
    }
    let geometry = KvGeometry {
        layers: params.total_layers.unwrap_or(0),
        kv_heads: params.kv_heads.unwrap_or(0),
        head_dim: params.head_dim.unwrap_or(0),
    };
    geometry.is_complete().then_some(geometry)
}

#[tauri::command]
pub async fn local_ai_estimate_memory(
    params: EstimateMemoryParams,
) -> Result<MemoryEstimation, String> {
    let models_dir = LocalModelStore::models_dir();
    let hw = detect_hardware(Some(&models_dir));
    Ok(calculate_memory_estimation(
        &hw,
        params.weights_size,
        params.context_length,
        &params.kv_cache_type,
        params.batch_size,
        estimation_geometry(&params),
    ))
}

#[tauri::command]
pub fn local_ai_hf_token_set(token: String) -> Result<(), String> {
    crate::local_ai::secret_store::save_hf_token(&token)
}

#[tauri::command]
pub fn local_ai_hf_token_status() -> bool {
    crate::local_ai::secret_store::has_hf_token()
}

#[tauri::command]
pub fn local_ai_hf_token_clear() -> Result<(), String> {
    crate::local_ai::secret_store::clear_hf_token()
}
