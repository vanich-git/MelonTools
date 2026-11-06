//! Tauri IPC commands for Local AI.

use serde::Deserialize;
use std::path::{Path, PathBuf};
use tauri::State;

use super::hardware::{
    calculate_configured_memory_estimation, detect_hardware, HardwareInfo, InferenceBackend,
    KvGeometry, MemoryEstimation,
};
use super::huggingface::{HFModelDetails, HFModelSearchResult, HuggingFaceService};
use super::local_models::{LocalModel, LocalModelSettingsPatch, LocalModelStore, RegistryHealth};
use super::local_runtime::{
    PublicationReporter, RuntimeInstallStatus, RuntimeMetrics, RuntimeStatusPayload,
    DEFAULT_LOG_LINES,
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
    state: State<'_, AppState>,
    id: String,
    settings: LocalModelSettingsPatch,
) -> Result<LocalModel, String> {
    let updated = LocalModelStore::update_model_settings(&id, settings)?;
    let status = state.local_runtime.get_status();
    // Do not start an idle model (or replace a different running model) just
    // because its settings were edited. A failed restart is a failed Save in
    // the UI, although the settings remain persisted for the next attempt.
    if should_restart_saved_model(
        &id,
        status.is_running,
        status.is_starting,
        status.model_id.as_deref(),
        status.starting_model_id.as_deref(),
    ) {
        let result = state.local_runtime.load_model(&id).await;
        sync_gateway_after_transition(&state);
        result?;
    }
    Ok(updated)
}

fn should_restart_saved_model(
    id: &str,
    running: bool,
    starting: bool,
    current_model: Option<&str>,
    starting_model: Option<&str>,
) -> bool {
    (running && current_model == Some(id)) || (starting && starting_model == Some(id))
}

#[cfg(test)]
mod settings_tests {
    use super::should_restart_saved_model;

    #[test]
    fn save_restarts_only_the_active_target() {
        assert!(should_restart_saved_model(
            "a",
            true,
            false,
            Some("a"),
            None
        ));
        assert!(should_restart_saved_model(
            "a",
            false,
            true,
            None,
            Some("a")
        ));
        assert!(!should_restart_saved_model(
            "a",
            false,
            false,
            Some("a"),
            None
        ));
        assert!(!should_restart_saved_model(
            "a",
            true,
            false,
            Some("b"),
            None
        ));
        assert!(!should_restart_saved_model(
            "a",
            false,
            true,
            None,
            Some("b")
        ));
    }
}

/// One publication attempt: rewrite the config, record the revision, then
/// wait for the public catalogue to show exactly `expected`.
///
/// A lost engine reload leaves the revision dirty (`request_resync`) so the
/// supervisor retries; a write failure never marks the revision synced. The
/// function takes write/read hooks and Tauri types stay out of it, so the
/// add/remove path is exercised without a live engine or `AppState`.
async fn publish_attempt<W, L, F>(
    reporter: &PublicationReporter,
    revision: u64,
    expected: std::collections::HashSet<String>,
    write: W,
    mut read_local_ids: L,
    interval: std::time::Duration,
) -> Result<(), String>
where
    W: FnOnce() -> Result<(), String>,
    L: FnMut() -> F,
    F: std::future::Future<Output = Result<Vec<String>, String>>,
{
    if let Err(error) = write() {
        // A failed rewrite means the catalogue still advertises the previous
        // lifecycle state. Keep the revision pending so the next supervisor
        // tick retries, and make the reason visible.
        eprintln!("local ai: gateway config write failed: {error}");
        let message = format!("The gateway config could not be written: {error}");
        if reporter.is_current(revision) {
            reporter.report(revision, Some(message.clone()));
        }
        return Err(message);
    }
    reporter.mark_synced(revision);
    let mut last_error: Option<String> = None;
    for _ in 0..20 {
        tokio::time::sleep(interval).await;
        match read_local_ids().await {
            Ok(ids) => {
                last_error = None;
                if ids.into_iter().collect::<std::collections::HashSet<_>>() == expected {
                    if reporter.is_current(revision) {
                        reporter.report(revision, None);
                    }
                    return Ok(());
                }
            }
            Err(error) => last_error = Some(error),
        }
    }
    // The runtime says the model is serving but the public catalogue never
    // caught up. This is the exact symptom a user sees as "the model is
    // running but the API does not list it", so keep it on the status payload
    // instead of swallowing it.
    let mut expected_list: Vec<String> = expected.into_iter().collect();
    expected_list.sort();
    let message = publication_failure_message(last_error.as_deref(), &expected_list);
    if reporter.is_current(revision) {
        // The write happens before the engine arms its file watcher, so this
        // exact write can be lost. Keep the revision dirty: the supervisor
        // retries the rewrite five seconds later instead of leaving the model
        // invisible until the user restarts the app.
        reporter.request_resync(revision);
        reporter.report(revision, Some(message.clone()));
    }
    Err(message)
}

/// Rewrites `config.yaml` when the runtime moved since the last write. The
/// engine hot-reloads the file, so the gateway catalogue cannot keep
/// advertising a model that stopped, crashed or was unloaded.
pub fn sync_gateway_after_transition(state: &AppState) {
    let Some(revision) = state.local_runtime.pending_gateway_revision() else {
        return;
    };
    let settings = state.settings();
    let reporter = state.local_runtime.publication_reporter();
    crate::bridge::invalidate_providers(&state.bridge);
    // Snapshot of what users should see after this revision. A start/stop that
    // lands while the poll runs bumps the revision, and this attempt then
    // leaves the caches and the Codex catalogue to the newer one.
    let expected: std::collections::HashSet<String> = crate::gateway::servable_local_models()
        .into_iter()
        .map(|model| crate::gateway::local_model_alias(&model.id))
        .collect();
    let invalidate_models = crate::bridge::model_cache_invalidator(&state.bridge);
    tauri::async_runtime::spawn(async move {
        let published = publish_attempt(
            &reporter,
            revision,
            expected,
            // Explicit publication (and every retry after a lost reload) must
            // replace the file even when the YAML is unchanged; ordinary
            // settings/catalogue writes keep the coalesced idempotent path.
            || crate::gateway::write_config_forced(&settings),
            || {
                let port = settings.port;
                let api_key = settings.api_key.clone();
                async move {
                    let models = crate::gateway::models(port, &api_key).await?;
                    Ok(models
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|model| model.get("id").and_then(serde_json::Value::as_str))
                        .filter(|id| id.starts_with("local/"))
                        .map(str::to_string)
                        .collect())
                }
            },
            std::time::Duration::from_millis(250),
        )
        .await;
        if published.is_err() || !reporter.is_current(revision) {
            return;
        }
        invalidate_models();
        if let Ok(client) = crate::quota::local_client() {
            // Publication already succeeded. A Codex catalogue failure must be
            // visible without pretending the model is missing from the
            // gateway, and it must not mark the gateway revision dirty.
            match crate::codex_route::sync_catalog(&client, settings.port, &settings.api_key).await {
                Ok(_) => reporter.report(revision, None),
                Err(error) => {
                    eprintln!("local ai: codex catalogue sync failed: {error}");
                    reporter.report(
                        revision,
                        Some(format!(
                            "The gateway published the local model, but the Codex catalogue \
                             could not be updated: {error}"
                        )),
                    );
                }
            }
        }
    });
}

/// The user-facing reason a lifecycle change is not visible in `/v1/models`.
/// Kept pure so the retry contract is testable without a live gateway.
fn publication_failure_message(last_error: Option<&str>, expected: &[String]) -> String {
    if let Some(error) = last_error {
        format!("The gateway could not be queried after the config rewrite: {error}")
    } else if expected.is_empty() {
        "The gateway still lists local models after they stopped.".to_string()
    } else {
        format!(
            "The gateway did not publish {} within 5 s. The engine may not have reloaded \
             config.yaml; retrying on the next check.",
            expected.join(", ")
        )
    }
}

#[cfg(test)]
mod publication_tests {
    use super::{publication_failure_message, publish_attempt};
    use crate::local_ai::local_runtime::LocalRuntimeManager;
    use std::collections::HashSet;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    fn expected(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|id| (*id).to_string()).collect()
    }

    #[tokio::test]
    async fn a_published_snapshot_marks_the_revision_synced() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(3);
        let reporter = manager.publication_reporter();
        let reads = Arc::new(AtomicUsize::new(0));
        let read_counter = reads.clone();
        let result = publish_attempt(
            &reporter,
            3,
            expected(&["local/a"]),
            || Ok(()),
            || {
                read_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec!["local/a".to_string()]))
            },
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_ok(), "{result:?}");
        assert_eq!(reads.load(Ordering::SeqCst), 1);
        assert_eq!(manager.pending_gateway_revision(), None);
        assert_eq!(manager.current_publication_error(), None);
    }

    #[tokio::test]
    async fn a_lost_reload_stays_dirty_and_is_reported() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(4);
        let reporter = manager.publication_reporter();
        let result = publish_attempt(
            &reporter,
            4,
            expected(&["local/a"]),
            || Ok(()),
            || std::future::ready(Ok(Vec::new())),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err());
        // Still pending: the supervisor rewrites the config, it is not marked
        // published just because the file was written.
        assert_eq!(manager.pending_gateway_revision(), Some(4));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(message.contains("did not publish"), "{message}");
    }

    #[tokio::test]
    async fn a_write_failure_keeps_the_revision_pending() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(5);
        let reporter = manager.publication_reporter();
        let result = publish_attempt(
            &reporter,
            5,
            expected(&["local/a"]),
            || Err("disk is full".to_string()),
            || std::future::ready(Ok(vec!["local/a".to_string()])),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err());
        assert_eq!(manager.pending_gateway_revision(), Some(5));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(message.contains("could not be written"), "{message}");
        assert!(message.contains("disk is full"), "{message}");
    }

    #[tokio::test]
    async fn a_stale_attempt_does_not_overwrite_the_newer_outcome() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(6);
        let reporter = manager.publication_reporter();
        reporter.report(6, Some("the newer attempt failed".to_string()));
        let result = publish_attempt(
            &reporter,
            5,
            expected(&["local/a"]),
            || Ok(()),
            || std::future::ready(Ok(vec!["local/a".to_string()])),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_ok());
        assert_eq!(
            manager.current_publication_error().as_deref(),
            Some("the newer attempt failed")
        );
        assert_eq!(manager.pending_gateway_revision(), Some(6));
    }

    #[test]
    fn publication_failure_names_the_gateway_error() {
        let message = publication_failure_message(Some("connection refused"), &["local/qwen".into()]);
        assert!(message.contains("connection refused"), "{message}");
    }

    #[test]
    fn publication_failure_lists_the_models_that_stayed_hidden() {
        let message = publication_failure_message(None, &["local/a".into(), "local/b".into()]);
        assert!(message.contains("local/a, local/b"), "{message}");
        assert!(message.contains("retrying"), "{message}");
    }

    #[test]
    fn publication_failure_reports_a_stale_catalogue_after_stop() {
        let message = publication_failure_message(None, &[]);
        assert!(message.contains("still lists local models"), "{message}");
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
    // A fresh Windows install has no engine binary. Download the official
    // build before the launch so a model starts out of the box, the way the
    // Mac build starts with its bundled runtime. The lifecycle lock is not
    // held here, so the user can still stop or cancel the download.
    state.local_runtime.ensure_engine().await?;
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
    sort: Option<String>,
    offset: Option<usize>,
) -> Result<Vec<HFModelSearchResult>, String> {
    let token = resolve_hf_token(token);
    HuggingFaceService::search_models(
        &query,
        limit.unwrap_or(30),
        token.as_deref(),
        sort.as_deref().unwrap_or("trendingScore"),
        offset.unwrap_or(0),
    )
    .await
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
    // Never send a saved Hub token to a renderer-supplied third-party host.
    HuggingFaceService::validate_repository_id(&request.repo_id)?;
    let expected = super::huggingface::HFGGUFFile::resolve_url(&request.repo_id, &request.filename);
    if request.download_url != expected {
        return Err("Download URL does not match the Hugging Face repository file".to_string());
    }
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
    #[serde(default)]
    pub gpu_offload_layers: Option<usize>,
    #[serde(default)]
    pub flash_attention: Option<bool>,
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
        ..Default::default()
    };
    geometry.is_complete().then_some(geometry)
}

#[tauri::command]
pub async fn local_ai_estimate_memory(
    params: EstimateMemoryParams,
) -> Result<MemoryEstimation, String> {
    let models_dir = LocalModelStore::models_dir();
    let hw = detect_hardware(Some(&models_dir));
    let model = params
        .model_id
        .as_deref()
        .and_then(LocalModelStore::get_model);
    let backend = model
        .as_ref()
        .map(|m| m.backend)
        .unwrap_or(InferenceBackend::Cpu);
    let gpu_layers = params.gpu_offload_layers.or_else(|| {
        model
            .as_ref()
            .and_then(|m| m.user_settings.gpu_offload_layers)
    });
    let flash = params.flash_attention.unwrap_or_else(|| {
        model
            .as_ref()
            .map(|m| m.user_settings.flash_attention)
            .unwrap_or(true)
    });
    Ok(calculate_configured_memory_estimation(
        &hw,
        params.weights_size,
        params.context_length,
        &params.kv_cache_type,
        params.batch_size,
        estimation_geometry(&params),
        gpu_layers,
        backend,
        flash,
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
