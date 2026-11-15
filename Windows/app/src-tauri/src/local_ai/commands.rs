//! Tauri IPC commands for Local AI.

use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
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

/// What one write+reload round published.
///
/// `expected` is the alias list of the YAML bytes written in the same round,
/// so the poll never waits for a set the file does not declare. `reload_error`
/// is `Some` when the engine refused or did not acknowledge the file; a 2xx
/// only means the reload was queued, and the catalogue poll can observe
/// convergence but never application. A refusal is therefore reported
/// directly instead of being polled away.
struct PublicationOutcome {
    expected: Vec<String>,
    reload_error: Option<String>,
    /// True when the engine rejected the management credential, as opposed to
    /// a transport failure. Five such refusals ban the loopback IP for 30
    /// minutes, so the caller must stop retrying until the secret changes.
    auth_refused: bool,
    /// Port and secret the published document was rendered for. The engine
    /// bans per address/credential, so a block must name the credential that
    /// was actually refused, not an older snapshot read before the write.
    fingerprint: u64,
    /// Another config writer replaced the file after this snapshot was written.
    /// Its reload is no longer the newest generation, so the round must not be
    /// reported or polled: the next round republishes the newer state.
    superseded: bool,
    /// The gateway was not accepting connections when this round was about to
    /// replace the file. Nothing was written; the supervisor retries on its
    /// normal tick, outside the failure backoff.
    unavailable: bool,
    /// Exact local generation of the bytes this outcome describes. The poll
    /// loop compares it before marking the revision synced, because a save can
    /// land after the reload and leave the catalogue looking converged for an
    /// obsolete document. An ordinary settings save advances this generation
    /// without changing the lifecycle revision, so the supervisor watches it
    /// separately from `pending_gateway_revision`.
    generation: u64,
}

impl PublicationOutcome {
    fn unavailable() -> Self {
        Self {
            expected: Vec::new(),
            reload_error: None,
            auth_refused: false,
            fingerprint: 0,
            superseded: false,
            unavailable: true,
            generation: 0,
        }
    }
}

/// One publication attempt that did not reach the catalogue.
#[derive(Debug)]
struct PublishError {
    message: String,
    auth_refused: bool,
    fingerprint: Option<u64>,
    /// The attempt stopped before replacing the file because the gateway was
    /// not listening. Callers must neither report nor enter the retry backoff.
    unavailable: bool,
    /// The engine acknowledged a document that declared local models and still
    /// served none of them. Every retry rewrites the same bytes, so the
    /// supervisor restarts the engine once to make it read the file at startup
    /// instead of through the management reload path.
    catalogue_empty: bool,
}

impl std::fmt::Display for PublishError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

/// One publication attempt: rewrite the config, record the revision, then
/// wait for the public catalogue to show exactly what that file declared.
///
/// The engine answers HTTP before its reload hook runs, so a 2xx is acceptance
/// and not application. Only a matching `/v1/models` snapshot marks the
/// revision converged: it is the only surface the app can observe, and it
/// cannot tell two generations apart when their aliases are identical. A
/// refusal ends the attempt immediately because polling cannot repair a file
/// the engine never adopted. The function takes
/// write/reload hooks and Tauri types stay out of it, so the add/remove path is
/// exercised without a live engine or `AppState`.
///
/// `write_and_reload` returns the aliases its own YAML declared: an alias list
/// captured before the render is a different snapshot, and a lifecycle change
/// between the two makes the poll wait for a model the file no longer lists.
async fn publish_attempt<W, WF, L, F>(
    reporter: &PublicationReporter,
    revision: u64,
    mut write_and_reload: W,
    mut read_local_ids: L,
    interval: std::time::Duration,
) -> Result<Option<u64>, PublishError>
where
    W: FnMut() -> WF,
    WF: std::future::Future<Output = Result<PublicationOutcome, String>>,
    L: FnMut() -> F,
    F: std::future::Future<Output = Result<Vec<String>, String>>,
{
    const ROUNDS: usize = 3;
    const POLLS_PER_ROUND: usize = 20;
    let mut last_error: Option<String> = None;
    let mut expected = Vec::new();
    let mut published = Vec::new();
    let mut auth_refused = false;
    let mut fingerprint = None;
    // Written before the poll loop reads it; the initial value only exists so
    // an early `continue` on a write error does not need a partial move.
    #[allow(unused_assignments)]
    let mut generation = 0;
    let mut superseded_rounds = 0;

    'rounds: for _round in 0..ROUNDS {
        let outcome = match write_and_reload().await {
            Ok(outcome) => outcome,
            Err(error) => {
                // A failed write is not a catalogue miss: name the write so
                // the two failures cannot be confused in the status payload.
                let message = format!(
                    "The rewritten config.yaml could not be written: {error}. The local model \
                     stays out of the API until the next successful write."
                );
                if reporter.is_current(revision) {
                    reporter.request_resync(revision);
                    reporter.report(revision, Some(message.clone()));
                }
                return Err(PublishError {
                    message,
                    auth_refused,
                    fingerprint,
                    unavailable: false,
                    catalogue_empty: false,
                });
            }
        };
        if outcome.unavailable {
            // No file was replaced and no engine request was made. This is a
            // preflight result, not a failed publication: leave the revision
            // pending, do not report an error, and retry on the supervisor tick.
            return Err(PublishError {
                message: "The gateway is not listening; the config was not rewritten.".to_string(),
                auth_refused: false,
                fingerprint: None,
                unavailable: true,
                catalogue_empty: false,
            });
        }
        expected = outcome.expected;
        // The comparison below is order-sensitive; the YAML order is a
        // rendering detail, so normalise once here instead of relying on the
        // renderer.
        expected.sort();
        expected.dedup();
        auth_refused = outcome.auth_refused;
        fingerprint = Some(outcome.fingerprint);
        generation = outcome.generation;
        if outcome.superseded {
            // A save landed after this snapshot was written. Polling the
            // catalogue now would either observe the old generation (and mark
            // it synced) or fail for a document that is already obsolete.
            superseded_rounds += 1;
            continue;
        }
        if let Some(error) = outcome.reload_error {
            // The engine queued or rejected the reload; either way the file is
            // not observably applied, and an empty catalogue is not evidence
            // that it was. Keep the revision dirty and say why.
            let message = publication_failure_message(None, &expected, &[], Some(&error));
            if reporter.is_current(revision) {
                reporter.request_resync(revision);
                reporter.report(revision, Some(message.clone()));
            }
            return Err(PublishError {
                message,
                auth_refused,
                fingerprint,
                unavailable: false,
                catalogue_empty: false,
            });
        }

        for _ in 0..POLLS_PER_ROUND {
            tokio::time::sleep(interval).await;
            match read_local_ids().await {
                Ok(ids) => {
                    let mut ids = ids;
                    ids.sort();
                    ids.dedup();
                    published = ids;
                    if published == expected {
                        // A save that landed after the reload check above has
                        // already replaced the file with newer bytes while the
                        // engine still runs this generation. The catalogue can
                        // look converged precisely because the aliases did not
                        // change, so do not mark a generation the file no
                        // longer describes.
                        //
                        // The check and the acknowledgement are one critical
                        // section with the file replacement: a local writer
                        // either lands before this block (the check sees the
                        // newer generation and the round stays pending) or after
                        // `mark_synced` (the supervisor then sees the newer
                        // generation on its next tick and republishes it as soon
                        // as the gateway is listening, whether or not the
                        // runtime is running; a later start also publishes the
                        // newest file). An ordinary settings save does not bump
                        // the lifecycle revision, so this generation comparison
                        // is what schedules its publication too. An external
                        // writer that edits config.yaml without bumping
                        // the counter is not covered. Zero means the caller
                        // supplied no local write (test doubles and the legacy
                        // path); there is nothing to compare against.
                        //
                        // The public catalogue lists exactly what the file just
                        // declared (including "no local models"). That is
                        // convergence of the visible surface, not proof that the
                        // new file replaced the old provider: both config GETs
                        // return the file or an in-memory config assigned before
                        // the async reload, and the engine exposes no completion
                        // signal. When aliases are unchanged and only the port or
                        // token moved, the old and the new generation look
                        // identical here. Marking it converged is still the right
                        // trade: the alternative is rewriting the same file on
                        // every 5 s supervisor tick forever, and the catalogue
                        // mismatch branch below stays the actionable signal.
                        let acknowledged = {
                            let generation_guard = crate::gateway::lock_config_generation();
                            let current =
                                generation == 0 || generation_guard.is_current(generation);
                            if current {
                                reporter.mark_synced(revision);
                                // Recorded under the same guard as the
                                // acknowledgement: a write cannot slip between
                                // them and leave a newer generation looking
                                // published.
                                mark_config_generation_published(generation);
                            }
                            current
                        };
                        if !acknowledged {
                            superseded_rounds += 1;
                            continue 'rounds;
                        }
                        // `is_current`/`report` take runtime and publication
                        // state locks. Keep them outside the generation guard:
                        // the writer's documented order is state first, then
                        // generation, and this call site must not add the
                        // reverse edge.
                        if reporter.is_current(revision) {
                            reporter.report(revision, None);
                        }
                        return Ok(fingerprint);
                    }
                }
                Err(error) => last_error = Some(error),
            }
        }
    }

    if superseded_rounds == ROUNDS {
        let message =
            "The gateway config kept being replaced by a newer settings generation while \
             it was being published. The local model stays out of the API until the next \
             publication applies the newest generation."
                .to_string();
        if reporter.is_current(revision) {
            reporter.request_resync(revision);
            reporter.report(revision, Some(message.clone()));
        }
        return Err(PublishError {
            message,
            auth_refused,
            fingerprint,
            unavailable: false,
            catalogue_empty: false,
        });
    }

    // The runtime says the model is serving but the public catalogue never
    // caught up. This is the exact symptom a user sees as "the model is
    // running but the API does not list it", so keep it on the status payload
    // instead of swallowing it.
    expected.sort();
    published.sort();
    let message = publication_failure_message(last_error.as_deref(), &expected, &published, None);
    if reporter.is_current(revision) {
        // Every round already rewrote the config; a model that is still
        // missing means the engine never adopted it. Keep the revision dirty
        // so the next lifecycle change republishes instead of leaving the
        // model invisible until the user restarts the app.
        reporter.request_resync(revision);
        reporter.report(revision, Some(message.clone()));
    }
    Err(PublishError {
        message,
        auth_refused,
        fingerprint,
        unavailable: false,
        catalogue_empty: catalogue_empty(
            last_error.as_deref(),
            &expected,
            &published,
            auth_refused,
        ),
    })
}

/// At most one publication runs at a time. The UI polls the runtime every two
/// seconds, while a failed attempt keeps rewriting for up to fifteen; without
/// this gate every poll would launch a rival rewrite of the same catalogue and
/// the engine would see a stream of half-raced files instead of one revision.
struct PublicationGate {
    in_flight: Mutex<Option<u64>>,
    /// The management credential the engine already rejected, together with
    /// its message. Retrying a bad secret is not harmless: five refusals from
    /// one IP make the engine ban the loopback address for 30 minutes. The
    /// local cooldown is longer than that ban, and exactly one probe is allowed
    /// once it expires so the credential is not locked out for the rest of the
    /// process after the timeout.
    auth_block: Mutex<Option<AuthBlock>>,
    /// Revision, earliest next attempt and consecutive failures. A publication
    /// that keeps failing must not rewrite the file on every supervisor tick;
    /// the delay grows from 15 s to 5 min and resets for a new revision.
    retry: Mutex<Option<(u64, std::time::Instant, u32)>>,
    /// Engine start count the two gates above were last evaluated against. A
    /// fresh process can have a different credential verdict, so its first
    /// supervisor tick clears both instead of inheriting the old one.
    engine_generation: Mutex<Option<u64>>,
}

/// The engine's brute-force guard bans a client address for 30 minutes after
/// five failures. Waiting exactly 30 minutes can race the engine's own timer
/// and land while the ban is still active, so the local cooldown is longer.
const AUTH_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(31 * 60);

struct AuthBlock {
    fingerprint: u64,
    message: String,
    until: std::time::Instant,
    /// A single attempt is allowed when the cooldown expires; without this a
    /// credential that starts working after the engine's ban expires would be
    /// rejected locally forever.
    probe_taken: bool,
}

/// The gate-visible result of one publication attempt. `fingerprint` is the
/// port/secret the last round actually used, which can differ from the pair the
/// attempt reserved its probe for.
enum AttemptResult<'a> {
    Success {
        fingerprint: Option<u64>,
    },
    Unavailable,
    Failure {
        auth_refused: bool,
        fingerprint: Option<u64>,
        message: &'a str,
    },
}

impl PublicationGate {
    const fn new() -> Self {
        Self {
            in_flight: Mutex::new(None),
            auth_block: Mutex::new(None),
            retry: Mutex::new(None),
            engine_generation: Mutex::new(None),
        }
    }

    /// Forget the old engine's credential verdict and backoff when this process
    /// spawned a replacement. Adoption deliberately keeps them: the same engine
    /// is still running and its ban must not be reset by reconnecting to it.
    fn observe_engine(&self, generation: u64) {
        let mut observed = self
            .engine_generation
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        // The counter only grows. A supervisor call that read an older value
        // before a restart must not overwrite the newer observation and clear a
        // ban that already belongs to the replacement engine.
        if observed.is_some_and(|seen| generation <= seen) {
            return;
        }
        *observed = Some(generation);
        // Keep the generation lock while clearing so the whole observation is
        // one state transition. `record_result` holds the same lock across its
        // check and writes: an observation therefore either finishes before a
        // result (and that result is rejected) or starts after it (and clears
        // what it wrote). A result cannot pass the check for the old engine and
        // then install a ban after the replacement was observed.
        *self.auth_block.lock().unwrap_or_else(|e| e.into_inner()) = None;
        *self.retry.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// Applies one finished attempt only if the engine that started it is still
    /// the observed one. The generation check and the auth/backoff writes share
    /// the `engine_generation` lock, so an observation either happens before the
    /// check (the result is discarded) or after the writes (it clears them).
    ///
    /// `reserved_fingerprint` is the port/secret whose single post-cooldown
    /// probe `auth_block` reserved before the attempt. A non-auth failure must
    /// return that probe, not the fingerprint of a config that changed during
    /// the attempt.
    fn record_result(
        &self,
        attempt_generation: u64,
        revision: u64,
        reserved_fingerprint: u64,
        result: AttemptResult<'_>,
    ) -> bool {
        let observed = self
            .engine_generation
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if *observed != Some(attempt_generation) {
            return false;
        }
        match result {
            AttemptResult::Success { fingerprint } => {
                let actual = fingerprint.unwrap_or(reserved_fingerprint);
                self.clear_auth(actual);
                if actual != reserved_fingerprint {
                    // The snapshot's credential was never probed; the success
                    // belongs to the newer one. Do not leave the old probe spent.
                    self.reset_probe(reserved_fingerprint);
                }
                self.clear_retry(revision);
            }
            AttemptResult::Unavailable => {
                self.reset_probe(reserved_fingerprint);
                self.clear_retry(revision);
            }
            AttemptResult::Failure {
                auth_refused,
                fingerprint,
                message,
            } => {
                if auth_refused {
                    // Name the credential that actually answered, even if the
                    // settings changed after the attempt reserved its probe.
                    self.block_auth(fingerprint.unwrap_or(reserved_fingerprint), message);
                } else {
                    self.reset_probe(reserved_fingerprint);
                }
                self.record_failure(revision);
            }
        }
        true
    }

    #[cfg(test)]
    fn forget_engine_for_test(&self) {
        *self
            .engine_generation
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// `Some` while the same port/secret pair is still known to be rejected.
    /// The check and the one-probe reservation happen under one lock, so two
    /// supervisor ticks cannot both spend the probe.
    fn auth_block(&self, fingerprint: u64) -> Option<String> {
        let mut block = self.auth_block.lock().unwrap_or_else(|e| e.into_inner());
        let Some(current) = block.as_mut() else {
            return None;
        };
        if current.fingerprint != fingerprint {
            return None;
        }
        if current.until > std::time::Instant::now() {
            return Some(current.message.clone());
        }
        if current.probe_taken {
            return Some(current.message.clone());
        }
        current.probe_taken = true;
        None
    }

    fn block_auth(&self, fingerprint: u64, message: &str) {
        let mut block = self.auth_block.lock().unwrap_or_else(|e| e.into_inner());
        *block = Some(AuthBlock {
            fingerprint,
            message: message.to_string(),
            until: std::time::Instant::now() + AUTH_COOLDOWN,
            probe_taken: false,
        });
    }

    /// A successful publication proves the credential works now; keeping the
    /// block would make the next failure inherit a stale message and expiry.
    fn clear_auth(&self, fingerprint: u64) {
        let mut block = self.auth_block.lock().unwrap_or_else(|e| e.into_inner());
        if block
            .as_ref()
            .is_some_and(|current| current.fingerprint == fingerprint)
        {
            *block = None;
        }
    }

    /// The single post-cooldown probe failed for a reason other than the
    /// credential (transport, engine down). It must not consume the probe:
    /// otherwise a temporary outage would leave that credential blocked for
    /// another full cooldown.
    fn reset_probe(&self, fingerprint: u64) {
        let mut block = self.auth_block.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(current) = block.as_mut() {
            if current.fingerprint == fingerprint && current.until <= std::time::Instant::now() {
                current.probe_taken = false;
            }
        }
    }

    /// Returns false while another revision is still publishing.
    fn claim(&self, revision: u64) -> bool {
        let mut slot = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        if slot.is_some() {
            return false;
        }
        *slot = Some(revision);
        true
    }

    /// How long `revision` must wait before another rewrite. `None` when the
    /// revision may start immediately (no failure yet, or the delay expired).
    fn retry_in(&self, revision: u64) -> Option<std::time::Duration> {
        let retry = self.retry.lock().unwrap_or_else(|e| e.into_inner());
        let (failed_revision, not_before, _) = retry.as_ref()?;
        if *failed_revision != revision {
            return None;
        }
        let now = std::time::Instant::now();
        (*not_before > now).then(|| *not_before - now)
    }

    /// Records one failed publication and returns the delay before the next
    /// attempt. Deliberately bounded: a permanently broken engine is retried,
    /// but not by rewriting `config.yaml` every five seconds.
    fn record_failure(&self, revision: u64) -> std::time::Duration {
        let mut retry = self.retry.lock().unwrap_or_else(|e| e.into_inner());
        let failures = retry
            .as_ref()
            .filter(|(failed_revision, _, _)| *failed_revision == revision)
            .map(|(_, _, failures)| *failures)
            .unwrap_or(0)
            .saturating_add(1);
        let seconds = 15u64.saturating_mul(1 << (failures - 1).min(5)).min(300);
        let delay = std::time::Duration::from_secs(seconds);
        *retry = Some((revision, std::time::Instant::now() + delay, failures));
        delay
    }

    /// A converged revision must not inherit an older delay.
    fn clear_retry(&self, revision: u64) {
        let mut retry = self.retry.lock().unwrap_or_else(|e| e.into_inner());
        if retry
            .as_ref()
            .is_some_and(|(failed_revision, _, _)| *failed_revision == revision)
        {
            *retry = None;
        }
    }

    /// Clears the slot only when it still belongs to `revision`, so a stale
    /// attempt cannot free the slot a newer one is holding.
    fn release(&self, revision: u64) {
        let mut slot = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        if *slot == Some(revision) {
            *slot = None;
        }
    }
}

static PUBLICATIONS: PublicationGate = PublicationGate::new();

/// Engine restart requested by a publication that the engine acknowledged but
/// did not serve. The supervisor owns the gateway handle, so it performs the
/// stop/start; this cell only carries the request and remembers the fingerprint
/// it was already spent on, which bounds the recovery to one restart per set of
/// published models.
#[derive(Default)]
struct RestartRequest {
    requested: Option<u64>,
    handled: Option<u64>,
}

static ENGINE_RESTART: Mutex<RestartRequest> = Mutex::new(RestartRequest {
    requested: None,
    handled: None,
});

/// Asks for one engine restart for `fingerprint`. A missing fingerprint means
/// the attempt never reached a document, so it cannot justify a restart.
fn request_engine_restart(fingerprint: Option<u64>) {
    let Some(fingerprint) = fingerprint else {
        return;
    };
    let mut request = ENGINE_RESTART
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if request.handled == Some(fingerprint) || request.requested == Some(fingerprint) {
        return;
    }
    request.requested = Some(fingerprint);
}

/// Takes a pending restart, marking its fingerprint spent. The supervisor calls
/// this on its normal tick, so the gateway handle is available there.
pub fn take_engine_restart_request() -> bool {
    let mut request = ENGINE_RESTART
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match request.requested.take() {
        Some(fingerprint) => {
            request.handled = Some(fingerprint);
            true
        }
        None => false,
    }
}

/// Appends everything needed to tell "the engine ignored the file" apart from
/// "the file never declared the model": the exact failure, the config bytes the
/// engine was pointed at, and the engine's own tail. The file is append-only so
/// an early failure stays readable after later retries.
fn record_publication_diagnostic(message: &str) {
    use std::io::Write;

    let dir = crate::paths::gateway_dir();
    let _ = std::fs::create_dir_all(&dir);
    let mut text = format!("\n=== {} ===\n{message}\n", chrono::Utc::now().to_rfc3339());
    let config = std::fs::read_to_string(crate::paths::config_path()).unwrap_or_default();
    text.push_str(&format!(
        "config.yaml: {} bytes at {}\n",
        config.len(),
        crate::paths::config_path().display()
    ));
    match config.find("melon-local-ai") {
        Some(index) => {
            let start = config[..index].rfind('\n').map_or(0, |line| line + 1);
            text.push_str("--- local block ---\n");
            text.push_str(&config[start..].chars().take(2000).collect::<String>());
            text.push('\n');
        }
        None => text.push_str("config.yaml has no melon-local-ai block\n"),
    }
    // Only the tail is reported, but the whole log used to be read into RAM;
    // the watchdog rotates it at 32 MiB and a long session can grow far past
    // that, so read a bounded window from the end instead.
    if let Ok(mut log) = std::fs::File::open(crate::paths::log_path()) {
        use std::io::{Read, Seek, SeekFrom};
        let length = log.metadata().map(|meta| meta.len()).unwrap_or(0);
        let window = 64 * 1024;
        let mut tail = String::new();
        if log
            .seek(SeekFrom::Start(length.saturating_sub(window)))
            .is_ok()
        {
            let _ = log.take(window).read_to_string(&mut tail);
        }
        // The window may start in the middle of a UTF-8 sequence or a line;
        // both make the first fragment meaningless.
        let tail = tail.split_once('\n').map(|(_, rest)| rest).unwrap_or(&tail);
        let mut tail: Vec<char> = tail.chars().rev().take(4000).collect();
        tail.reverse();
        text.push_str("--- gateway.log tail ---\n");
        text.extend(tail);
        text.push('\n');
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("publication-diagnostics.txt"))
        .and_then(|mut file| file.write_all(text.as_bytes()));
}

/// Releases an attempt whose result belongs to a replaced engine.
///
/// A successful attempt may already have marked the revision synced before the
/// replacement was observed, so dropping the result without requesting a resync
/// would let the new process inherit the old process's acknowledgement. A
/// failure or unavailable result is already pending, and the compare-exchange
/// in `request_resync` then fails harmlessly.
fn discard_replaced_attempt(
    gate: &PublicationGate,
    reporter: &PublicationReporter,
    engine_generation: &AtomicU64,
    revision: u64,
) {
    reporter.request_resync(revision);
    gate.observe_engine(engine_generation.load(Ordering::Acquire));
    gate.release(revision);
}

/// Newest config generation a publication wrote and acknowledged. Ordinary
/// settings saves replace `config.yaml` without creating a lifecycle revision,
/// so the supervisor compares this value with [`crate::gateway::config_generation`]
/// to notice that the engine has not seen the newest file yet. `u64::MAX` means
/// this process has not published anything.
static PUBLISHED_CONFIG_GENERATION: AtomicU64 = AtomicU64::new(u64::MAX);

fn mark_config_generation_published(generation: u64) {
    if generation != 0 {
        PUBLISHED_CONFIG_GENERATION.store(generation, Ordering::Release);
    }
}

/// True when a publication already recorded this generation, or when the
/// caller supplied no local write at all (zero). An external edit is not
/// tracked either way.
fn config_generation_is_published(generation: u64) -> bool {
    generation == 0 || PUBLISHED_CONFIG_GENERATION.load(Ordering::Acquire) == generation
}

/// Revision to publish now, or `None` when both the lifecycle state and the
/// config file are current.
///
/// A pending lifecycle revision is the original trigger. A changed generation
/// covers ordinary settings/catalogue writes, which replace the file but do
/// not advance that revision; without this branch `mark_synced` made them
/// invisible to the supervisor. Zero means a test double or the legacy call
/// path supplied no local write.
fn next_publication_revision(
    pending_revision: Option<u64>,
    current_revision: u64,
    generation: u64,
) -> Option<u64> {
    if let Some(revision) = pending_revision {
        return Some(revision);
    }
    if config_generation_is_published(generation) {
        return None;
    }
    // A changed generation means an ordinary settings/catalogue save replaced
    // the file. Publish it even when the local runtime is stopped: the gateway
    // may be running independently, and the transport probe below decides
    // whether a write is useful. The next lifecycle start also republishes.
    Some(current_revision)
}

/// A stable-enough identity of the management credential in this process.
///
/// The engine's brute-force guard bans the loopback address, so changing the
/// port or secret does not by itself lift that ban. This is only a local
/// attribution key: it lets a corrected credential be tried once instead of
/// inheriting the old slot's cooldown, and it makes a result clear or block the
/// pair that actually answered rather than the snapshot that reserved it.
fn publication_fingerprint(port: u16, management_secret: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    port.hash(&mut hasher);
    management_secret.hash(&mut hasher);
    hasher.finish()
}

/// Rewrites `config.yaml` when the runtime moved since the last write, or when
/// an ordinary settings/catalogue save replaced the file after the last
/// publication. The engine hot-reloads the file, so the gateway catalogue
/// cannot keep advertising a model that stopped, crashed or was unloaded.
pub fn sync_gateway_after_transition(state: &AppState) {
    let engine_generation = state.gw.started_generation_handle();
    PUBLICATIONS.observe_engine(engine_generation.load(Ordering::Acquire));
    let pending = state.local_runtime.pending_gateway_revision();
    let generation = crate::gateway::config_generation();
    if pending.is_none() && config_generation_is_published(generation) {
        return;
    }
    let Some(revision) =
        next_publication_revision(pending, state.local_runtime.revision(), generation)
    else {
        return;
    };
    if !PUBLICATIONS.claim(revision) {
        return;
    }
    // One snapshot, used only to identify the credential and to answer "is this
    // attempt already known to be refused". The bytes that are published are
    // rendered from a fresh snapshot inside every round: a settings save while
    // a retry is in flight must not be overwritten with the older values.
    let settings = state.settings();
    let fingerprint = publication_fingerprint(settings.port, &settings.management_secret);
    // A stopped gateway cannot apply a rewrite. Probe here, before spawning a
    // task or clearing the UI caches, so an unavailable gateway costs one
    // bounded loopback connection per supervisor tick and no write attempts.
    // The task and the write closure probe again to close the race with a
    // gateway that stops after this check.
    if !crate::gateway::is_listening_blocking(settings.port) {
        // A revision that failed while the gateway was up must not stay in
        // backoff after it stopped: the next listening tick publishes at once.
        // An allowed credential probe that never reached the engine must not
        // stay spent either. Record this through the generation guard: a
        // restart that landed during the blocking probe must not let this
        // stale tick clear the replacement engine's backoff.
        let preflight_generation = engine_generation.load(Ordering::Acquire);
        if !PUBLICATIONS.record_result(
            preflight_generation,
            revision,
            fingerprint,
            AttemptResult::Unavailable,
        ) {
            PUBLICATIONS.observe_engine(engine_generation.load(Ordering::Acquire));
        }
        PUBLICATIONS.release(revision);
        return;
    }
    // The supervisor runs every five seconds. Without a delay, a gateway that
    // listens but keeps failing the reload would rewrite the file on every
    // tick; the status message already explains the failure, so wait out the
    // backoff. This gate must precede the credential probe: otherwise the one
    // post-cooldown probe is consumed and the tick returns without attempting
    // anything, leaving the probe spent until yet another cooldown.
    if PUBLICATIONS.retry_in(revision).is_some() {
        PUBLICATIONS.release(revision);
        return;
    }
    if let Some(message) = PUBLICATIONS.auth_block(fingerprint) {
        PUBLICATIONS.release(revision);
        let reporter = state.local_runtime.publication_reporter();
        if reporter.is_current(revision) {
            reporter.report(revision, Some(message));
        }
        return;
    }
    let settings_slot = state.settings.clone();
    let reporter = state.local_runtime.publication_reporter();
    let attempt_generation = engine_generation.load(Ordering::Acquire);
    crate::bridge::invalidate_providers(&state.bridge);
    let invalidate_models = crate::bridge::model_cache_invalidator(&state.bridge);
    tauri::async_runtime::spawn(async move {
        // A replacement engine may have started between the supervisor probe
        // and this task. Its verdict is not this attempt's to record.
        let current = engine_generation.load(Ordering::Acquire);
        if current != attempt_generation {
            PUBLICATIONS.observe_engine(current);
            PUBLICATIONS.release(revision);
            return;
        }
        let published = publish_attempt(
            &reporter,
            revision,
            // Explicit publication (and every retry after a lost reload) must
            // replace the file even when the YAML is unchanged; ordinary
            // settings/catalogue writes keep the coalesced idempotent path.
            // The management reload that follows does not trust the watcher:
            // a missed notification used to keep the model out of the
            // catalogue for the whole life of the engine process.
            || {
                let settings_slot = settings_slot.clone();
                async move {
                    // A forced write is only useful when there is a gateway to
                    // reload it. Check the configured port immediately before
                    // every round: a stopped gateway must not keep replacing the
                    // same file on each supervisor tick. The probe is transport
                    // only, so an API-key change can still be published and a
                    // bad credential is reported by the management reload.
                    let port = settings_slot
                        .lock()
                        .map(|settings| settings.port)
                        .unwrap_or_default();
                    if !crate::gateway::is_listening(port).await {
                        return Ok(PublicationOutcome::unavailable());
                    }
                    // Loading and writing happen under the config lock: a save
                    // that lands between a clone taken here and the write can
                    // no longer be overwritten by this older snapshot.
                    let publication = crate::gateway::write_config_current_forced(|| {
                        settings_slot
                            .lock()
                            .map(|s| s.clone())
                            .unwrap_or_default()
                    })?;
                    let fingerprint = publication_fingerprint(
                        publication.port,
                        &publication.management_secret,
                    );
                    let generation = publication.generation;
                    // The expected set is the alias list of the bytes just
                    // written, not a second snapshot: the two used to be taken
                    // at different moments, so a stop in between made the poll
                    // wait for a catalogue entry the YAML no longer declared.
                    let expected = publication.local_models;
                    // The write lock covers the file replacement only. A save
                    // can land between that replacement and the PUT below;
                    // sending this snapshot then would overwrite the newer
                    // file and apply it. Skip the PUT and let the next round
                    // publish the newer state instead.
                    if crate::gateway::config_generation() != generation {
                        return Ok(PublicationOutcome {
                            expected,
                            reload_error: None,
                            auth_refused: false,
                            fingerprint,
                            superseded: true,
                            unavailable: false,
                            generation,
                        });
                    }
                    // The engine persists config.yaml itself in another process
                    // (normalizing the management secret), so that write cannot
                    // take the in-process generation lock. It does not add a
                    // local generation: a local writer that lands before or
                    // during the PUT bumps the counter and is caught below, and
                    // `reload_config` waits for the engine to report the digest
                    // it saved as applied. A late external edit without a bump
                    // remains outside this counter.
                    match crate::gateway::reload_config(
                        publication.port,
                        &publication.management_secret,
                        &publication.yaml,
                    )
                    .await
                    {
                        // The 2xx means the reload was queued, not applied. The
                        // catalogue poll below observes convergence only; it
                        // cannot distinguish an applied file from an identical
                        // previous generation.
                        Ok(()) => {
                            // The reload completed, but a concurrent save may
                            // have replaced the file while the PUT was in
                            // flight; the engine has then applied the older
                            // bytes. Restore the newest file immediately and
                            // leave the revision pending for the next round.
                            let superseded =
                                crate::gateway::config_generation() != generation;
                            if superseded {
                                // The disk can hold the older body even when
                                // the in-memory last-written map still names
                                // the newest one: the engine persists the body
                                // it was sent. Restore must therefore replace
                                // the bytes unconditionally.
                                if let Err(error) =
                                    crate::gateway::write_config_current_forced(|| {
                                        settings_slot
                                            .lock()
                                            .map(|s| s.clone())
                                            .unwrap_or_default()
                                    })
                                {
                                    eprintln!(
                                        "local ai: could not restore the newest config.yaml: {error}"
                                    );
                                }
                            }
                            Ok(PublicationOutcome {
                                expected,
                                reload_error: None,
                                auth_refused: false,
                                fingerprint,
                                superseded,
                                unavailable: false,
                                generation,
                            })
                        }
                        Err(failure) => {
                            eprintln!(
                                "local ai: gateway reload rejected the config: {failure}"
                            );
                            // The PUT can have saved the body and still fail
                            // afterwards (the engine writes before it applies,
                            // and a rejected apply answers non-2xx). If a newer
                            // save landed in that window, the old bytes are now
                            // on disk; restore the newest state before retrying.
                            let superseded =
                                crate::gateway::config_generation() != generation;
                            if superseded {
                                // The disk can hold the older body even when
                                // the in-memory last-written map still names
                                // the newest one: the engine persists the body
                                // it was sent. Restore must therefore replace
                                // the bytes unconditionally.
                                if let Err(error) =
                                    crate::gateway::write_config_current_forced(|| {
                                        settings_slot
                                            .lock()
                                            .map(|s| s.clone())
                                            .unwrap_or_default()
                                    })
                                {
                                    eprintln!(
                                        "local ai: could not restore the newest config.yaml: {error}"
                                    );
                                }
                            }
                            // A refused credential describes the snapshot that
                            // was sent, not the newer one on disk. Blocking on
                            // it would poison the next round, which has a new
                            // fingerprint and may well succeed.
                            let auth_refused = failure.is_auth() && !superseded;
                            Ok(PublicationOutcome {
                                expected,
                                reload_error: Some(failure.message().to_string()),
                                auth_refused,
                                fingerprint,
                                superseded,
                                unavailable: false,
                                generation,
                            })
                        }
                    }
                }
            },
            || {
                let settings_slot = settings_slot.clone();
                async move {
                    let settings = settings_slot
                        .lock()
                        .map(|s| s.clone())
                        .unwrap_or_default();
                    let models = crate::gateway::models(settings.port, &settings.api_key).await?;
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
        // A spawn after this attempt was armed is indistinguishable from one
        // that happened before the request: the counter cannot say which
        // process answered. `record_result` checks the generation and writes
        // the verdict under the same lock as `observe_engine`, so a result
        // that raced with the replacement is discarded instead of charging the
        // old engine's 401 or backoff to the new one. The cost is that a
        // verdict produced by the replacement may also be discarded; the next
        // supervisor tick reattempts it. That is one extra probe per restart,
        // not a guarantee of zero engine failures across repeated restarts.
        let result = match &published {
            Ok(fingerprint) => AttemptResult::Success {
                fingerprint: *fingerprint,
            },
            Err(error) if error.unavailable => AttemptResult::Unavailable,
            Err(error) => {
                if error.catalogue_empty {
                    record_publication_diagnostic(&error.message);
                    request_engine_restart(error.fingerprint);
                }
                AttemptResult::Failure {
                    auth_refused: error.auth_refused,
                    fingerprint: error.fingerprint,
                    message: &error.message,
                }
            }
        };
        let unavailable = matches!(&published, Err(error) if error.unavailable);
        if !PUBLICATIONS.record_result(attempt_generation, revision, fingerprint, result) {
            // A replacement was observed after this attempt was armed. A
            // successful attempt may already have marked the revision synced
            // inside `publish_attempt`; clear that acknowledgement so the new
            // process gets its own publication instead of inheriting the old
            // process's.
            discard_replaced_attempt(&PUBLICATIONS, &reporter, &engine_generation, revision);
            return;
        }
        PUBLICATIONS.release(revision);
        if unavailable {
            // The gateway went away between the supervisor probe and this
            // round. Nothing was written, so there is no failed publication to
            // report or back off. The single allowed credential probe was
            // already returned by `record_result`.
            return;
        }
        if published.is_err() || !reporter.is_current(revision) {
            return;
        }
        let settings = settings_slot.lock().map(|s| s.clone()).unwrap_or_default();
        invalidate_models();
        if let Ok(client) = crate::quota::local_client() {
            // Publication already succeeded. A Codex catalogue failure must be
            // visible without pretending the model is missing from the
            // gateway, and it must not mark the gateway revision dirty.
            match crate::codex_route::sync_catalog(&client, settings.port, &settings.api_key).await
            {
                Ok(_) => reporter.report(revision, None),
                Err(error) => {
                    eprintln!("local ai: codex catalogue sync failed: {error}");
                    reporter.report(
                        revision,
                        Some(format!(
                            "The gateway catalogue lists the local model, but the Codex \
                             catalogue could not be updated: {error}"
                        )),
                    );
                }
            }
        }
    });
}

/// True only when a round wrote a document that declared local models, the
/// engine acknowledged it, and the catalogue was then read successfully and
/// still held none.
///
/// This is the one failure a rewrite cannot fix: the bytes on disk are already
/// the ones the app wants, so the engine did not apply what it acknowledged.
/// A refused credential, a failed write and an unreadable catalogue all have
/// their own recovery, and restarting there would throw away a working process
/// for a transient error.
fn catalogue_empty(
    last_error: Option<&str>,
    expected: &[String],
    published: &[String],
    auth_refused: bool,
) -> bool {
    last_error.is_none() && !expected.is_empty() && published.is_empty() && !auth_refused
}

/// The user-facing reason a lifecycle change is not visible in `/v1/models`.
/// Kept pure so the retry contract is testable without a live gateway.
///
/// The reload diagnostic comes first: when the engine rejected the bytes, the
/// catalogue still holds the previous state and no amount of polling will
/// change it, so the engine's own message is the only useful sentence. When
/// the reload went through, the ids the catalogue actually serves tell a
/// stale entry apart from a missing one.
fn publication_failure_message(
    last_error: Option<&str>,
    expected: &[String],
    seen: &[String],
    reload_error: Option<&str>,
) -> String {
    if let Some(error) = last_error {
        format!("The gateway could not be queried after the config rewrite: {error}")
    } else if let Some(error) = reload_error {
        // "Did not confirm" covers both a non-2xx answer and a 2xx without the
        // v8 status document; only the engine text says whether the YAML was
        // refused, stored-but-not-reloaded or never reached the port.
        format!(
            "The engine did not confirm the rewritten config.yaml: {error}. The gateway keeps \
             the previous catalogue until a reload is acknowledged."
        )
    } else if expected.is_empty() {
        "The gateway still lists local models after they stopped.".to_string()
    } else if seen.is_empty() {
        // Only observed facts: the request was acknowledged, the file declared
        // these aliases, and /v1/models kept returning an empty local set.
        // Whether the provider entry was dropped, rejected during expansion or
        // never applied cannot be told from the public catalogue.
        format!(
            "The engine acknowledged the rewritten config.yaml, but /v1/models listed no local \
             model on any check. The file declared {}. The management API accepted the request; \
             whether the engine applied it is not visible from the catalogue. The next check \
             rewrites the file.",
            expected.join(", ")
        )
    } else {
        format!(
            "The engine acknowledged the rewritten config.yaml, but /v1/models lists {} instead \
             of {}. The catalogue still serves a set the file does not declare; the next check \
             rewrites the file.",
            seen.join(", "),
            expected.join(", ")
        )
    }
}

#[cfg(test)]
mod publication_tests {
    use super::{
        catalogue_empty, discard_replaced_attempt, mark_config_generation_published,
        next_publication_revision, publication_failure_message, publication_fingerprint,
        publish_attempt, sync_gateway_after_transition, AttemptResult, AuthBlock, PublicationGate,
        PublicationOutcome, PUBLICATIONS, PUBLISHED_CONFIG_GENERATION,
    };
    use crate::local_ai::local_runtime::LocalRuntimeManager;
    use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    /// The publication gate is process-global; tests that drive the real
    /// supervisor entry point must not observe another test's block.
    static SYNC_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn publication_state(port: u16, revision: u64) -> crate::AppState {
        let runtime = LocalRuntimeManager::for_test();
        runtime.set_revision_for_test(revision);
        crate::AppState {
            gw: crate::gateway::Gateway::new(),
            bridge: crate::bridge::BridgeState::new(),
            settings: Arc::new(Mutex::new(crate::settings::Settings {
                port,
                management_secret: "test-management-secret".to_string(),
                ..Default::default()
            })),
            watchdog: Mutex::new(crate::Watchdog::default()),
            update: Mutex::new(None),
            island: Mutex::new(None),
            island_watch: AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
            runtime_stop_attempted: AtomicBool::new(false),
            local_runtime: Arc::new(runtime),
            download_manager: Arc::new(crate::local_ai::ModelDownloadManager::new()),
        }
    }

    /// A round that wrote a file declaring exactly these aliases and whose
    /// reload the engine acknowledged.
    fn outcome(ids: &[&str]) -> PublicationOutcome {
        PublicationOutcome {
            expected: ids.iter().map(|id| (*id).to_string()).collect(),
            reload_error: None,
            auth_refused: false,
            fingerprint: 0,
            superseded: false,
            unavailable: false,
            generation: 0,
        }
    }

    /// A round whose file reached the disk but whose reload was refused.
    fn refused(ids: &[&str], error: &str) -> PublicationOutcome {
        PublicationOutcome {
            expected: ids.iter().map(|id| (*id).to_string()).collect(),
            reload_error: Some(error.to_string()),
            auth_refused: false,
            fingerprint: 0,
            superseded: false,
            unavailable: false,
            generation: 0,
        }
    }

    /// A round the engine answered with 401/403. The credential itself is the
    /// problem, so the retry loop must stop instead of burning the five
    /// attempts that trigger the 30 minute ban.
    fn refused_auth(ids: &[&str], error: &str) -> PublicationOutcome {
        PublicationOutcome {
            expected: ids.iter().map(|id| (*id).to_string()).collect(),
            reload_error: Some(error.to_string()),
            auth_refused: true,
            fingerprint: 0,
            superseded: false,
            unavailable: false,
            generation: 0,
        }
    }

    /// A save that lands after this snapshot was written makes the snapshot
    /// obsolete; polling would mark a generation the engine did not apply.
    fn superseded() -> PublicationOutcome {
        PublicationOutcome {
            expected: vec!["local/a".to_string()],
            reload_error: None,
            auth_refused: false,
            fingerprint: 0,
            superseded: true,
            unavailable: false,
            generation: 0,
        }
    }

    #[tokio::test]
    async fn a_superseded_snapshot_is_neither_polled_nor_marked_synced() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(5);
        let reporter = manager.publication_reporter();
        let reads = Arc::new(AtomicUsize::new(0));
        let read_counter = reads.clone();
        let result = publish_attempt(
            &reporter,
            5,
            || std::future::ready(Ok(superseded())),
            || {
                read_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec!["local/a".to_string()]))
            },
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err(), "an obsolete snapshot must stay pending");
        assert_eq!(
            reads.load(Ordering::SeqCst),
            0,
            "an obsolete snapshot must not be polled"
        );
        assert_eq!(manager.pending_gateway_revision(), Some(5));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(
            message.contains("replaced by a newer settings generation"),
            "{message}"
        );
    }

    #[tokio::test]
    async fn a_converged_catalogue_does_not_acknowledge_a_replaced_generation() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(6);
        let reporter = manager.publication_reporter();
        let reads = Arc::new(AtomicUsize::new(0));
        let read_counter = reads.clone();
        let result = publish_attempt(
            &reporter,
            6,
            || {
                let mut stale = outcome(&["local/a"]);
                // No live counter can equal this value: it stands for a
                // snapshot whose generation a newer local save has replaced.
                stale.generation = u64::MAX;
                std::future::ready(Ok(stale))
            },
            || {
                read_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec!["local/a".to_string()]))
            },
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err(), "a replaced generation must stay pending");
        assert!(
            reads.load(Ordering::SeqCst) > 0,
            "the catalogue did converge; the rejection must come from the generation check"
        );
        assert_eq!(manager.pending_gateway_revision(), Some(6));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(
            message.contains("replaced by a newer settings generation"),
            "{message}"
        );
    }

    /// An ordinary settings save replaces `config.yaml` but does not bump the
    /// lifecycle revision. After a successful publication the supervisor must
    /// still notice the newer generation and republish it; otherwise the
    /// engine keeps the previous catalogue until the next start/stop.
    #[test]
    fn an_ordinary_config_write_schedules_a_publication_after_mark_synced() {
        let path = std::env::temp_dir().join(format!(
            "melon-config-publication-{}-{}.yaml",
            std::process::id(),
            line!()
        ));
        let _ = std::fs::remove_file(&path);

        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(5);
        manager.mark_gateway_synced(5);
        assert_eq!(
            manager.pending_gateway_revision(),
            None,
            "the lifecycle revision starts converged"
        );

        let first = crate::gateway::write_config_for_test(&path, "config-version: 8\n", false)
            .unwrap()
            .expect("the first write must reach the file");
        mark_config_generation_published(first);
        assert_eq!(next_publication_revision(None, 5, first), None);

        let second = crate::gateway::write_config_for_test(&path, "config-version: 9\n", false)
            .unwrap()
            .expect("the changed write must reach the file");
        assert!(second > first);
        assert_eq!(
            manager.pending_gateway_revision(),
            None,
            "an ordinary write must not fabricate a lifecycle revision"
        );
        assert_eq!(
            next_publication_revision(None, manager.revision(), second),
            Some(5),
            "the generation difference must schedule a publication"
        );
        // The scheduler takes no runtime-state input: a stopped runtime and a
        // running one produce the same decision here. Whether a write is useful
        // is decided later by the gateway availability probe.
        assert_eq!(
            next_publication_revision(Some(5), manager.revision(), second),
            Some(5),
            "a lifecycle revision still publishes while the runtime is stopped"
        );

        mark_config_generation_published(second);
        assert_eq!(next_publication_revision(None, 5, second), None);

        PUBLISHED_CONFIG_GENERATION.store(u64::MAX, Ordering::Release);
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn an_unavailable_gateway_does_not_write_or_report_a_failure() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(7);
        let reporter = manager.publication_reporter();

        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);

        let writes = Arc::new(AtomicUsize::new(0));
        let write_counter = writes.clone();
        let result = publish_attempt(
            &reporter,
            7,
            || {
                let write_counter = write_counter.clone();
                async move {
                    if !crate::gateway::is_listening(port).await {
                        return Ok(PublicationOutcome::unavailable());
                    }
                    write_counter.fetch_add(1, Ordering::SeqCst);
                    Ok(outcome(&["local/a"]))
                }
            },
            || std::future::ready(Ok(Vec::<String>::new())),
            Duration::from_millis(1),
        )
        .await;

        let error = result.expect_err("a stopped gateway cannot publish");
        assert!(error.unavailable, "{error:?}");
        assert_eq!(
            writes.load(Ordering::SeqCst),
            0,
            "the unavailable preflight must run before the forced write"
        );
        assert_eq!(
            manager.pending_gateway_revision(),
            Some(7),
            "the revision must stay pending for the next supervisor tick"
        );
        assert_eq!(
            manager.current_publication_error(),
            None,
            "an unavailable gateway is not a failed publication"
        );
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
            || std::future::ready(Ok(outcome(&["local/a"]))),
            || {
                read_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(vec!["local/a".to_string()]))
            },
            Duration::from_millis(1),
        )
        .await;
        assert_eq!(result.unwrap(), Some(0));
        assert_eq!(reads.load(Ordering::SeqCst), 1);
        assert_eq!(manager.pending_gateway_revision(), None);
        assert_eq!(manager.current_publication_error(), None);
    }

    #[test]
    fn the_poll_loop_cannot_start_a_rival_publication() {
        let gate = PublicationGate::new();
        assert!(gate.claim(4));
        assert!(!gate.claim(4), "the same revision must not run twice");
        assert!(!gate.claim(5), "a newer revision waits for the current one");
        gate.release(4);
        assert!(gate.claim(5));
    }

    /// A broken engine must not turn the five-second supervisor into a
    /// rewrite loop. The delay is per revision: a new lifecycle transition
    /// retries immediately, a converged revision clears the delay.
    #[test]
    fn a_failed_publication_backs_off_within_the_same_revision() {
        let gate = PublicationGate::new();
        assert!(
            gate.retry_in(7).is_none(),
            "a fresh revision is attempted at once"
        );
        assert_eq!(gate.record_failure(7), std::time::Duration::from_secs(15));
        assert!(gate.retry_in(7).is_some());
        assert!(
            gate.retry_in(8).is_none(),
            "a new revision must not inherit the delay"
        );
        assert_eq!(gate.record_failure(7), std::time::Duration::from_secs(30));
        gate.clear_retry(7);
        assert!(gate.retry_in(7).is_none());
    }

    /// A restart is the last resort for an acknowledged document that still
    /// served nothing. Every other failure has its own recovery, and a restart
    /// there would replace a healthy process for a transient error.
    #[test]
    fn only_a_clean_empty_catalogue_asks_for_a_restart() {
        let expected = vec!["local/qwen3.5-2b-bf16".to_string()];
        assert!(catalogue_empty(None, &expected, &[], false));
        assert!(
            !catalogue_empty(Some("connect refused"), &expected, &[], false),
            "a read failure is not an empty catalogue"
        );
        assert!(
            !catalogue_empty(None, &[], &[], false),
            "nothing was expected, so nothing is missing"
        );
        assert!(
            !catalogue_empty(None, &expected, &expected, false),
            "a served alias is not a failure"
        );
        assert!(
            !catalogue_empty(None, &expected, &[], true),
            "a refused credential must keep its own cooldown"
        );
    }

    /// The engine bans an address for 30 minutes; the local cooldown must
    /// outlast that ban and then allow exactly one probe, so a corrected
    /// secret is neither retried into a longer ban nor locked out forever.
    #[test]
    fn an_auth_block_outlives_the_engine_ban_and_allows_one_probe() {
        let gate = PublicationGate::new();
        gate.block_auth(11, "401 unauthorized");
        assert!(gate.auth_block(11).is_some());
        assert!(
            gate.auth_block(12).is_none(),
            "a different port/secret must not inherit the block"
        );

        // Expire the cooldown without waiting 31 minutes.
        gate.auth_block.lock().unwrap().as_mut().unwrap().until =
            std::time::Instant::now() - Duration::from_secs(1);

        assert!(
            gate.auth_block(11).is_none(),
            "the first call after expiry is the one probe"
        );
        assert!(
            gate.auth_block(11).is_some(),
            "a second call must not spend another probe"
        );

        // The probe failed for a transport reason, not a bad credential: the
        // next attempt must be allowed to probe again instead of blocking
        // forever.
        gate.reset_probe(11);
        assert!(gate.auth_block(11).is_none());

        // A successful publication clears the block entirely.
        gate.clear_auth(11);
        assert!(gate.auth_block(11).is_none());
    }

    #[test]
    fn a_refused_probe_restarts_the_cooldown() {
        let gate = PublicationGate::new();
        gate.block_auth(11, "401 unauthorized");
        gate.auth_block.lock().unwrap().as_mut().unwrap().until =
            std::time::Instant::now() - Duration::from_secs(1);
        assert!(gate.auth_block(11).is_none(), "probe is allowed");
        gate.block_auth(11, "401 unauthorized again");
        assert!(
            gate.auth_block(11).is_some(),
            "a refused probe must start a new cooldown"
        );
    }

    /// Block and backoff are recorded before the claim is released; otherwise
    /// the next supervisor tick can claim the slot in the gap and immediately
    /// repeat the request the engine just refused.
    #[test]
    fn a_released_claim_already_carries_the_failure_state() {
        let gate = PublicationGate::new();
        assert!(gate.claim(4));
        gate.block_auth(4, "401 unauthorized");
        gate.record_failure(4);
        gate.release(4);
        assert!(gate.auth_block(4).is_some());
        assert!(gate.retry_in(4).is_some());
    }

    #[test]
    fn releasing_a_stale_revision_keeps_the_current_claim() {
        let gate = PublicationGate::new();
        assert!(gate.claim(4));
        gate.release(3);
        assert!(!gate.claim(5), "the stale release freed the wrong slot");
        gate.release(4);
        assert!(gate.claim(5));
    }

    #[tokio::test]
    async fn a_lost_first_reload_is_repaired_by_a_fresh_write() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(7);
        let reporter = manager.publication_reporter();
        let writes = Arc::new(AtomicUsize::new(0));
        let reads = Arc::new(AtomicUsize::new(0));
        let write_counter = writes.clone();
        let read_counter = reads.clone();
        let result = publish_attempt(
            &reporter,
            7,
            move || {
                write_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(outcome(&["local/a"])))
            },
            move || {
                let seen = read_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(if seen < 20 {
                    Vec::new()
                } else {
                    vec!["local/a".to_string()]
                }))
            },
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_ok(), "{result:?}");
        assert_eq!(writes.load(Ordering::SeqCst), 2);
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
            || std::future::ready(Ok(outcome(&["local/a"]))),
            || std::future::ready(Ok(Vec::new())),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err());
        // Still pending: the supervisor rewrites the config, it is not marked
        // published just because the file was written.
        assert_eq!(manager.pending_gateway_revision(), Some(4));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(message.contains("acknowledged"), "{message}");
        assert!(message.contains("no local model on any check"), "{message}");
    }

    /// A refused reload is reported from the refusal, never from a catalogue
    /// poll, and it is attempted once per publication: repeating a refused
    /// reload multiplies failed management authentications without changing
    /// the answer. The supervisor retries on its next pass.
    #[tokio::test]
    async fn a_refused_reload_is_attempted_once_and_never_polled() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(13);
        let reporter = manager.publication_reporter();
        let writes = Arc::new(AtomicUsize::new(0));
        let reads = Arc::new(AtomicUsize::new(0));
        let write_counter = writes.clone();
        let read_counter = reads.clone();
        let result = publish_attempt(
            &reporter,
            13,
            move || {
                write_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(refused(&["local/a"], "HTTP 500: reload failed")))
            },
            move || {
                read_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(Vec::new()))
            },
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err());
        assert_eq!(
            writes.load(Ordering::SeqCst),
            1,
            "one reload attempt per publication"
        );
        assert_eq!(
            reads.load(Ordering::SeqCst),
            0,
            "no poll without an acknowledgement"
        );
        assert_eq!(manager.pending_gateway_revision(), Some(13));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(message.contains("HTTP 500: reload failed"), "{message}");
        assert!(!message.contains("rejected"), "{message}");
    }

    /// A refused reload with an empty expected set is still a refusal: the
    /// empty catalogue is not evidence that the file was applied, so the
    /// revision stays dirty and the reason stays visible instead of returning
    /// a quiet success.
    #[tokio::test]
    async fn a_refused_reload_with_nothing_to_publish_is_reported_and_pending() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(14);
        let reporter = manager.publication_reporter();
        let result = publish_attempt(
            &reporter,
            14,
            || std::future::ready(Ok(refused(&[], "connection refused"))),
            || std::future::ready(Ok(Vec::new())),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err(), "{result:?}");
        assert_eq!(manager.pending_gateway_revision(), Some(14));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(message.contains("connection refused"), "{message}");
    }

    #[tokio::test]
    async fn a_round_with_nothing_to_publish_is_quiet() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(11);
        let reporter = manager.publication_reporter();
        let result = publish_attempt(
            &reporter,
            11,
            || std::future::ready(Ok(outcome(&[]))),
            || std::future::ready(Ok(Vec::new())),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_ok(), "{result:?}");
        assert_eq!(manager.pending_gateway_revision(), None);
        assert_eq!(manager.current_publication_error(), None);
    }

    /// The expected set follows the YAML of the round that wrote it. A model
    /// that stops between two rounds must not leave the poll waiting for an
    /// alias the newer file no longer declares.
    #[tokio::test]
    async fn a_later_round_publishes_the_set_its_own_file_declares() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(12);
        let reporter = manager.publication_reporter();
        let writes = Arc::new(AtomicUsize::new(0));
        let write_counter = writes.clone();
        let result = publish_attempt(
            &reporter,
            12,
            move || {
                let round = write_counter.fetch_add(1, Ordering::SeqCst);
                // Round 1 promised `local/a`; by round 2 the model stopped and
                // the rendered file declares nothing.
                std::future::ready(Ok(if round == 0 {
                    outcome(&["local/a"])
                } else {
                    outcome(&[])
                }))
            },
            || std::future::ready(Ok(Vec::new())),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_ok(), "{result:?}");
        assert_eq!(writes.load(Ordering::SeqCst), 2);
        assert_eq!(manager.pending_gateway_revision(), None);
    }

    #[tokio::test]
    async fn a_write_failure_keeps_the_revision_pending() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(5);
        let reporter = manager.publication_reporter();
        let result = publish_attempt(
            &reporter,
            5,
            || std::future::ready(Err("disk is full".to_string())),
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
            || std::future::ready(Ok(outcome(&["local/a"]))),
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
        let message = publication_failure_message(
            Some("connection refused"),
            &["local/qwen".into()],
            &[],
            None,
        );
        assert!(message.contains("connection refused"), "{message}");
    }

    #[test]
    fn publication_failure_names_the_reload_rejection() {
        let message = publication_failure_message(
            None,
            &["local/qwen".into()],
            &[],
            Some("HTTP 400: yaml: line 12: did not find expected key"),
        );
        assert!(message.contains("did not confirm"), "{message}");
        assert!(message.contains("HTTP 400"), "{message}");
        assert!(message.contains("did not find expected key"), "{message}");
        assert!(message.contains("previous catalogue"), "{message}");
    }

    #[tokio::test]
    async fn a_refused_reload_is_reported_and_keeps_the_revision_pending() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(8);
        let reporter = manager.publication_reporter();
        let reads = Arc::new(AtomicUsize::new(0));
        let read_counter = reads.clone();
        let result = publish_attempt(
            &reporter,
            8,
            // The file reached the disk but the engine answered with an error.
            || std::future::ready(Ok(refused(&["local/a"], "HTTP 400: invalid_yaml"))),
            move || {
                read_counter.fetch_add(1, Ordering::SeqCst);
                std::future::ready(Ok(Vec::new()))
            },
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err());
        // The engine never adopted the file, so the revision still owes the
        // catalogue and the supervisor must rewrite it.
        assert_eq!(manager.pending_gateway_revision(), Some(8));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(message.contains("HTTP 400"), "{message}");
        assert!(message.contains("invalid_yaml"), "{message}");
    }

    #[test]
    fn publication_failure_lists_the_models_that_stayed_hidden() {
        let message =
            publication_failure_message(None, &["local/a".into(), "local/b".into()], &[], None);
        assert!(message.contains("local/a, local/b"), "{message}");
        assert!(message.contains("no local model on any check"), "{message}");
        // The catalogue is the only evidence: the message must not claim the
        // provider entry was dropped, because that was never observed.
        assert!(!message.contains("dropped"), "{message}");
    }

    #[test]
    fn publication_failure_lists_the_stale_catalogue_entries() {
        let message =
            publication_failure_message(None, &["local/a".into()], &["local/old".into()], None);
        assert!(message.contains("local/old"), "{message}");
        assert!(message.contains("instead of local/a"), "{message}");
    }

    #[test]
    fn publication_failure_reports_a_stale_catalogue_after_stop() {
        let message = publication_failure_message(None, &[], &[], None);
        assert!(message.contains("still lists local models"), "{message}");
    }

    #[test]
    fn a_rejected_credential_is_not_retried_for_the_same_port_and_secret() {
        let gate = PublicationGate::new();
        let fingerprint = publication_fingerprint(18317, "melon-mgmt-1234");
        assert_eq!(gate.auth_block(fingerprint), None);
        gate.block_auth(fingerprint, "HTTP 401: unauthorized");
        assert_eq!(
            gate.auth_block(fingerprint).as_deref(),
            Some("HTTP 401: unauthorized")
        );
        // A different port or secret is a different credential, and the engine
        // resets its failure counter on a successful authentication.
        assert_eq!(
            gate.auth_block(publication_fingerprint(18318, "melon-mgmt-1234")),
            None
        );
        assert_eq!(
            gate.auth_block(publication_fingerprint(18317, "other-secret")),
            None
        );
    }

    /// Two supervisor calls can overlap: one reads generation 1, a restart
    /// bumps to 2, and the stale call runs its observation last. It must not
    /// clear the ban that already belongs to engine 2.
    #[test]
    fn a_stale_supervisor_tick_does_not_clear_the_new_engine_state() {
        let gate = PublicationGate::new();
        let fingerprint = publication_fingerprint(18318, "melon-mgmt-1234");
        gate.observe_engine(2);
        gate.block_auth(fingerprint, "HTTP 401: engine 2");
        gate.record_failure(7);

        gate.observe_engine(1);

        assert_eq!(
            gate.auth_block(fingerprint).as_deref(),
            Some("HTTP 401: engine 2")
        );
        assert!(gate.retry_in(7).is_some());
    }

    #[tokio::test]
    async fn a_rejected_credential_marks_the_failure_as_an_auth_refusal() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(15);
        let reporter = manager.publication_reporter();
        let error = publish_attempt(
            &reporter,
            15,
            || std::future::ready(Ok(refused_auth(&[], "HTTP 401: unauthorized"))),
            || std::future::ready(Ok(Vec::new())),
            Duration::from_millis(1),
        )
        .await
        .unwrap_err();
        assert!(error.auth_refused, "{}", error.message);
        assert_eq!(manager.pending_gateway_revision(), Some(15));
    }

    #[tokio::test]
    async fn an_unreachable_catalogue_keeps_the_revision_pending() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(9);
        let reporter = manager.publication_reporter();
        let result = publish_attempt(
            &reporter,
            9,
            || std::future::ready(Ok(outcome(&["local/a"]))),
            || std::future::ready(Err("connection refused".to_string())),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err(), "{result:?}");
        assert_eq!(manager.pending_gateway_revision(), Some(9));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(message.contains("could not be queried"), "{message}");
        assert!(message.contains("connection refused"), "{message}");
    }

    /// A refused reload outranks a silent catalogue: the engine's own refusal
    /// is the actionable fact, and the old code reported `Ok(None)` here and
    /// marked the revision synced.
    #[tokio::test]
    async fn a_refused_reload_outranks_an_unreachable_catalogue() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(10);
        let reporter = manager.publication_reporter();
        let result = publish_attempt(
            &reporter,
            10,
            || std::future::ready(Ok(refused(&["local/a"], "HTTP 401: unauthorized"))),
            || std::future::ready(Err("connection refused".to_string())),
            Duration::from_millis(1),
        )
        .await;
        assert!(result.is_err(), "{result:?}");
        assert_eq!(manager.pending_gateway_revision(), Some(10));
        let message = manager.current_publication_error().unwrap_or_default();
        assert!(message.contains("HTTP 401: unauthorized"), "{message}");
    }

    /// A real restart means a new process with a new credential verdict. The
    /// supervisor entry point must forget the old 31 minute ban and its retry
    /// delay; otherwise the new engine is punished for the old one.
    #[test]
    fn a_spawned_engine_clears_the_old_auth_block_and_backoff() {
        let _guard = SYNC_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Reserve then release a loopback port: the sync preflight sees a
        // stopped gateway and does not spawn a publication task.
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);

        let state = publication_state(port, 3);
        PUBLICATIONS.forget_engine_for_test();
        PUBLICATIONS.observe_engine(0);
        let fingerprint = publication_fingerprint(port, "test-management-secret");
        PUBLICATIONS.block_auth(fingerprint, "HTTP 401: old engine");
        // Keyed to another revision so the unavailable branch's
        // `clear_retry(3)` cannot make this assertion pass by accident.
        PUBLICATIONS.record_failure(2);

        state.gw.record_started_for_test();
        sync_gateway_after_transition(&state);

        assert_eq!(
            PUBLICATIONS.auth_block(fingerprint),
            None,
            "the new engine must get its own credential probe"
        );
        assert_eq!(
            PUBLICATIONS.retry_in(2),
            None,
            "the new engine must not inherit the old backoff"
        );
    }

    /// Adoption reuses the same process. Resetting its ban would allow five
    /// more refusals against an engine that is still enforcing it.
    #[test]
    fn an_adopted_engine_keeps_the_auth_block_and_backoff() {
        let _guard = SYNC_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let state = publication_state(port, 3);
        PUBLICATIONS.forget_engine_for_test();
        PUBLICATIONS.observe_engine(0);
        let fingerprint = publication_fingerprint(port, "test-management-secret");
        PUBLICATIONS.block_auth(fingerprint, "HTTP 401: still running");
        PUBLICATIONS.record_failure(3);

        // No `record_started_for_test`: this is the `adopted` result.
        sync_gateway_after_transition(&state);
        assert!(PUBLICATIONS.retry_in(3).is_some());
        assert!(
            !PUBLICATIONS
                .auth_block
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .as_ref()
                .unwrap()
                .probe_taken
        );

        // With no backoff left, the credential gate itself must still refuse.
        PUBLICATIONS.clear_retry(3);
        sync_gateway_after_transition(&state);
        let block = PUBLICATIONS
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let block = block.as_ref().expect("the ban must survive adoption");
        assert!(!block.probe_taken, "no probe may be spent on adoption");
        drop(listener);
    }

    /// An expired cooldown allows one probe. If the gateway disappears before
    /// that probe can be used, the probe must be returned, not left spent until
    /// the next 31 minute cooldown.
    #[test]
    fn an_unavailable_gateway_returns_a_spent_auth_probe() {
        let _guard = SYNC_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);

        let state = publication_state(port, 3);
        PUBLICATIONS.forget_engine_for_test();
        PUBLICATIONS.observe_engine(0);
        let fingerprint = publication_fingerprint(port, "test-management-secret");
        *PUBLICATIONS
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(AuthBlock {
            fingerprint,
            message: "HTTP 401: previous attempt".to_string(),
            until: Instant::now() - Duration::from_secs(1),
            probe_taken: true,
        });
        PUBLICATIONS.record_failure(3);

        sync_gateway_after_transition(&state);

        let block = PUBLICATIONS
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        assert!(
            !block.as_ref().unwrap().probe_taken,
            "an unavailable round must return the probe"
        );
        drop(block);
        assert_eq!(
            PUBLICATIONS.auth_block(fingerprint),
            None,
            "the next listening tick must be allowed to probe"
        );
        assert_eq!(PUBLICATIONS.retry_in(3), None);
    }

    /// The supervisor can observe a replacement engine while an older
    /// publication is still between its generation check and `block_auth`.
    /// The gate must make that check and the ban one atomic step under the
    /// generation lock; otherwise the late ban punishes the new process for
    /// 31 minutes. This is a real interleaving, not a sequential imitation:
    /// the old result holds `engine_generation` and waits for `auth_block`;
    /// this thread verifies it still holds the generation lock, then starts
    /// the new observation, which blocks on that same lock until the old
    /// result has written its verdict.
    #[test]
    fn a_late_result_cannot_ban_the_replacement_engine() {
        let gate = Arc::new(PublicationGate::new());
        let fingerprint = publication_fingerprint(18318, "melon-mgmt-1234");
        gate.observe_engine(1);

        let auth_guard = gate
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let old_gate = gate.clone();
        let old = std::thread::spawn(move || {
            old_gate.record_result(
                1,
                9,
                fingerprint,
                AttemptResult::Failure {
                    auth_refused: true,
                    fingerprint: Some(fingerprint),
                    message: "HTTP 401: engine 1",
                },
            )
        });
        // Wait until the old result owns the generation lock and is blocked on
        // the auth gate held by this thread.
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match gate.engine_generation.try_lock() {
                Ok(guard) => drop(guard),
                Err(std::sync::TryLockError::WouldBlock) => break,
                Err(std::sync::TryLockError::Poisoned(_)) => {
                    panic!("the test poisoned the generation lock")
                }
            }
            assert!(
                Instant::now() < deadline,
                "the old result never reached the auth gate"
            );
            std::thread::yield_now();
        }

        // Observing `WouldBlock` once only proves the old result held the lock
        // at that instant. It must keep holding it until it has written the
        // verdict; checking again after a short pause distinguishes that from
        // an implementation that releases the lock before `block_auth`.
        for _ in 0..100 {
            assert!(
                matches!(
                    gate.engine_generation.try_lock(),
                    Err(std::sync::TryLockError::WouldBlock)
                ),
                "the old result released the generation lock before writing its verdict"
            );
            std::thread::sleep(Duration::from_millis(1));
        }

        let new_gate = gate.clone();
        let new = std::thread::spawn(move || new_gate.observe_engine(2));
        drop(auth_guard);

        assert!(old.join().unwrap(), "the old result should be accepted");
        new.join().unwrap();
        assert!(
            gate.auth_block
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_none(),
            "the observation of engine 2 must clear the result written for engine 1"
        );
        assert_eq!(gate.retry_in(9), None);
    }

    /// The other ordering: the observation wins the generation lock first, so
    /// the old result must be rejected outright and never write a ban.
    #[test]
    fn a_result_from_a_replaced_engine_is_not_recorded() {
        let gate = PublicationGate::new();
        let fingerprint = publication_fingerprint(18318, "melon-mgmt-1234");
        gate.observe_engine(1);
        gate.observe_engine(2);

        let accepted = gate.record_result(
            1,
            9,
            fingerprint,
            AttemptResult::Failure {
                auth_refused: true,
                fingerprint: Some(fingerprint),
                message: "HTTP 401: engine 1",
            },
        );

        assert!(
            !accepted,
            "engine 1's result must not be recorded for engine 2"
        );
        assert!(gate
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_none());
        assert_eq!(gate.retry_in(9), None);
    }

    /// A successful attempt can acknowledge its revision before `record_result`
    /// sees that a replacement engine was observed. The discarded success must
    /// not leave that acknowledgement in place: the new process needs its own
    /// publication.
    #[test]
    fn a_discarded_success_is_republished_to_the_new_engine() {
        let manager = LocalRuntimeManager::for_test();
        manager.set_revision_for_test(9);
        let reporter = manager.publication_reporter();
        reporter.mark_synced(9);
        assert_eq!(manager.pending_gateway_revision(), None);

        let gate = PublicationGate::new();
        assert!(gate.claim(9));
        gate.observe_engine(1);
        let engine_generation = AtomicU64::new(2);

        discard_replaced_attempt(&gate, &reporter, &engine_generation, 9);

        assert_eq!(
            manager.pending_gateway_revision(),
            Some(9),
            "the discarded success must be published again"
        );
        assert!(
            gate.claim(10),
            "the rejected attempt must release the in-flight slot"
        );
    }

    /// The supervisor's blocking availability probe can straddle a restart.
    /// Its "unavailable" result must not clear the replacement engine's
    /// backoff, even though both attempts carry the same lifecycle revision.
    #[test]
    fn a_stale_unavailable_result_cannot_clear_the_new_engines_backoff() {
        let gate = PublicationGate::new();
        let fingerprint = publication_fingerprint(18318, "melon-mgmt-1234");
        gate.observe_engine(2);
        gate.record_failure(9);

        let accepted = gate.record_result(1, 9, fingerprint, AttemptResult::Unavailable);

        assert!(
            !accepted,
            "engine 1's observation must not clear engine 2's delay"
        );
        assert!(gate.retry_in(9).is_some());

        // A late success is just as dangerous: it would clear the replacement
        // engine's block and backoff for the same credential.
        gate.block_auth(fingerprint, "HTTP 401: replacement engine");
        gate.record_failure(9);
        let accepted = gate.record_result(
            1,
            9,
            fingerprint,
            AttemptResult::Success {
                fingerprint: Some(fingerprint),
            },
        );

        assert!(
            !accepted,
            "engine 1's success must not clear engine 2's block"
        );
        assert!(gate.auth_block(fingerprint).is_some());
        assert!(gate.retry_in(9).is_some());
    }

    /// The attempt reserved the probe for the snapshot's port/secret, but the
    /// write closure rendered a newer settings snapshot. A non-auth failure
    /// must return the reserved probe, not silently leave it spent because the
    /// error names the newer fingerprint.
    #[test]
    fn a_non_auth_failure_returns_the_probe_reserved_for_the_snapshot() {
        let gate = PublicationGate::new();
        let reserved = publication_fingerprint(18317, "melon-mgmt-old");
        let changed = publication_fingerprint(18318, "melon-mgmt-new");
        gate.observe_engine(1);
        *gate
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(AuthBlock {
            fingerprint: reserved,
            message: "HTTP 401: previous attempt".to_string(),
            until: Instant::now() - Duration::from_secs(1),
            probe_taken: false,
        });

        assert_eq!(
            gate.auth_block(reserved),
            None,
            "the cooldown allows a probe"
        );
        assert!(
            gate.auth_block
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .as_ref()
                .expect("the expired block is kept")
                .probe_taken,
            "the successful reservation spends the only probe"
        );
        assert!(gate.record_result(
            1,
            9,
            reserved,
            AttemptResult::Failure {
                auth_refused: false,
                fingerprint: Some(changed),
                message: "transport failed before authentication",
            },
        ));

        let block = gate
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let block = block.as_ref().expect("the expired block is kept");
        assert_eq!(block.fingerprint, reserved);
        assert!(
            !block.probe_taken,
            "the reserved credential's probe must be returned"
        );
        assert!(gate.retry_in(9).is_some());
    }

    /// An auth refusal names the credential that answered, even when it differs
    /// from the snapshot that reserved the probe.
    #[test]
    fn an_auth_result_blocks_the_credential_that_actually_answered() {
        let gate = PublicationGate::new();
        let reserved = publication_fingerprint(18317, "melon-mgmt-old");
        let changed = publication_fingerprint(18318, "melon-mgmt-new");
        gate.observe_engine(1);

        assert!(gate.record_result(
            1,
            9,
            reserved,
            AttemptResult::Failure {
                auth_refused: true,
                fingerprint: Some(changed),
                message: "HTTP 401: changed credential",
            },
        ));

        let block = gate
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let block = block.as_ref().expect("the refusal must be remembered");
        assert_eq!(block.fingerprint, changed);
        assert_eq!(block.message, "HTTP 401: changed credential");
        assert!(gate.retry_in(9).is_some());
    }

    /// A success proves the credential that actually published works. Clearing
    /// the snapshot's fingerprint instead would leave a block on the credential
    /// that just succeeded.
    #[test]
    fn a_success_clears_the_credential_that_actually_published() {
        let gate = PublicationGate::new();
        let reserved = publication_fingerprint(18317, "melon-mgmt-old");
        let changed = publication_fingerprint(18318, "melon-mgmt-new");
        gate.observe_engine(1);
        gate.block_auth(changed, "HTTP 401: changed credential");

        assert!(gate.record_result(
            1,
            3,
            reserved,
            AttemptResult::Success {
                fingerprint: Some(changed),
            },
        ));

        assert!(gate
            .auth_block
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_none());
        assert_eq!(gate.retry_in(3), None);
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

/// What the local router answers for `GET /v1/models` with its own key.
///
/// The llama.cpp router is launched with `--api-key`, so the same request
/// without the credential answers 401 even while the model serves normally.
/// Reading the catalogue with the key separates "the engine has no models"
/// from "this probe forgot to authenticate", which used to look identical to
/// the user.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalApiCatalogue {
    pub models: Vec<String>,
    pub verified: bool,
    pub error: Option<String>,
}

const LOCAL_API_CATALOGUE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

#[tauri::command]
pub async fn local_ai_api_catalogue() -> Result<LocalApiCatalogue, String> {
    let port = super::get_runtime_port();
    let token = super::get_or_create_internal_token();
    let client = super::loopback_client()?;
    let mut catalogue = LocalApiCatalogue {
        models: Vec::new(),
        verified: false,
        error: None,
    };
    let response = client
        .get(format!("http://127.0.0.1:{port}/v1/models"))
        .bearer_auth(&token)
        .timeout(LOCAL_API_CATALOGUE_TIMEOUT)
        .send()
        .await;
    match response {
        Ok(response) if response.status().is_success() => {
            // A 200 is not yet a catalogue: a proxy error page or a partial
            // body must not be reported as a verified empty list, because the
            // UI shows "no models" instead of "the catalogue is unreadable".
            match response.json::<serde_json::Value>().await {
                Ok(body) => match body.get("data").and_then(serde_json::Value::as_array) {
                    Some(entries) => {
                        catalogue.models = entries
                            .iter()
                            .filter_map(|model| model.get("id").and_then(serde_json::Value::as_str))
                            .map(str::to_string)
                            .collect();
                        catalogue.verified = true;
                    }
                    None => {
                        catalogue.error =
                            Some("The engine returned a catalogue without a model list.".into());
                    }
                },
                Err(error) => {
                    catalogue.error = Some(format!("Unreadable model catalogue: {error}"));
                }
            }
        }
        Ok(response) => {
            catalogue.error = Some(format!("HTTP {}", response.status().as_u16()));
        }
        Err(error) => catalogue.error = Some(error.to_string()),
    }
    Ok(catalogue)
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
    state.local_runtime.set_custom_binary_path(pb).await
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

/// Resolves the avatars of every publisher on the current catalogue page in a
/// single round trip. Publishers the Hub knows nothing about are absent from
/// the map, and the renderer keeps its initials placeholder for them.
#[tauri::command]
pub async fn local_ai_hf_avatars(
    owners: Vec<String>,
    token: Option<String>,
) -> Result<std::collections::HashMap<String, String>, String> {
    let token = resolve_hf_token(token);
    Ok(HuggingFaceService::avatars(owners, token.as_deref()).await)
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
