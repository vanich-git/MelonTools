//! The local Codex API gateway (CLIProxyAPI sidecar): config, auth sync,
//! process lifecycle and the live request-rate counter.

use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use crate::paths;
use crate::settings::Settings;
use crate::vault::{self, Account};

pub struct Gateway {
    pub child: Mutex<Option<Child>>,
    /// Incremented only when `start` spawns a fresh engine. Adopting an
    /// already-running process keeps it unchanged, which lets the publication
    /// gate distinguish a real restart from a resumed one.
    started_generation: Arc<AtomicU64>,
    /// Set once `stop` has swept the engine. `RunEvent::Exit`, the tray quit
    /// and the updater all stop the gateway, and the second call must not run
    /// the image-name `taskkill /IM` sweep again (§2.2, W9).
    stopped: Mutex<bool>,
}

impl Gateway {
    pub fn new() -> Self {
        Self {
            child: Mutex::new(None),
            started_generation: Arc::new(AtomicU64::new(0)),
            stopped: Mutex::new(false),
        }
    }

    /// Records that an engine may be running again. Called when `start` adopts
    /// a live engine or stores a freshly spawned child, so a later `stop` does
    /// not mistake it for the repeat call described above.
    fn mark_running(&self) {
        if let Ok(mut stopped) = self.stopped.lock() {
            *stopped = false;
        }
    }

    /// Handle to the count of fresh engine processes this process has spawned.
    /// The count advances before the health poll, so a started-but-unhealthy
    /// child is still a new process for the publication gate.
    pub(crate) fn started_generation_handle(&self) -> Arc<AtomicU64> {
        self.started_generation.clone()
    }

    #[cfg(test)]
    pub(crate) fn record_started_for_test(&self) {
        self.started_generation.fetch_add(1, Ordering::AcqRel);
    }

    /// True when a child process we spawned is still alive. Adopted engines
    /// have no child handle; the caller combines this with the watchdog flag.
    pub fn child_running(&self) -> bool {
        let Ok(mut guard) = self.child.lock() else {
            return false;
        };
        let Some(child) = guard.as_mut() else {
            return false;
        };
        matches!(child.try_wait(), Ok(None))
    }
}

const SIDECAR_NAMES: [&str; 2] = ["cliproxyapi-x86_64-pc-windows-msvc.exe", "cliproxyapi.exe"];

/// One client for local management and health calls. The 1.5 s guard used to
/// build a fresh `reqwest::Client` (with its own connection pool) per tick.
static GATEWAY_CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

fn gateway_client() -> Option<&'static reqwest::Client> {
    if let Some(client) = GATEWAY_CLIENT.get() {
        return Some(client);
    }
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()
        .ok()?;
    let _ = GATEWAY_CLIENT.set(client);
    GATEWAY_CLIENT.get()
}

pub fn resolve_sidecar() -> Option<PathBuf> {
    resolve_sidecar_checked().ok()
}

/// The embedded engine comes first (single-file install); loose files next to
/// the app stay supported for development and manual installs.
fn resolve_sidecar_checked() -> Result<PathBuf, String> {
    if let Ok(path) = crate::engine::ensure_engine() {
        return Ok(path);
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(from_env) = std::env::var("MELON_GATEWAY_BIN") {
        candidates.push(PathBuf::from(from_env));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for name in SIDECAR_NAMES {
                candidates.push(dir.join(name));
                candidates.push(dir.join("binaries").join(name));
            }
        }
    }
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("binaries");
    for name in SIDECAR_NAMES {
        candidates.push(dev.join(name));
    }
    candidates
        .into_iter()
        .find(|p| p.exists())
        .ok_or_else(|| "не удалось распаковать движок шлюза".to_string())
}

fn create_no_window(_cmd: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        _cmd.creation_flags(0x0800_0000);
    }
}

// MARK: - Config

/// Built-in OpenCode catalogue, also listed on the routing page when the
/// provider has no fetched model list yet.
pub(crate) fn opencode_builtin_models() -> &'static [(&'static str, &'static str)] {
    OPENCODE_MODELS
}

const OPENCODE_MODELS: &[(&str, &str)] = &[
    ("claude-haiku-5-5", "Claude Haiku 5.5"),
    ("deepseek-v4-pro", "DeepSeek V4 Pro"),
    ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash"),
    ("glm-5.3", "GLM 5.3"),
    ("glm-5.3-flash", "GLM 5.3 Flash"),
    ("gpt-6-luna", "GPT 6 Luna"),
    ("grok-4.7", "Grok 4.7"),
    ("kimi-k2.7-code", "Kimi K2.7 Code"),
    ("kimi-k3", "Kimi K3"),
    ("minimax-m3", "MiniMax M3"),
    ("qwen3.6-plus", "Qwen3.6 Plus"),
    ("qwen3.8-flash", "Qwen3.8 Flash"),
];

/// Reads the live settings while holding the config write lock, so the snapshot
/// that is rendered is the snapshot that is written. Passing an already cloned
/// `Settings` leaves a window where a concurrent save replaces the file with
/// newer values and this call then overwrites it with the older clone.
#[cfg(test)]
pub fn write_config(settings: &Settings) -> Result<(), String> {
    write_config_from(|| settings.clone(), false).map(|_| ())
}

pub fn write_config_current<F>(load: F) -> Result<(), String>
where
    F: FnOnce() -> Settings,
{
    write_config_from(load, false).map(|_| ())
}

/// One config generation: the exact YAML handed to the engine, the endpoint
/// that YAML was rendered for, and the local aliases it declares. Callers must
/// never re-derive any of these from a second snapshot — the gateway then
/// waits for a catalogue, or authenticates against a port, that does not match
/// the file it wrote.
pub struct ConfigPublication {
    pub yaml: String,
    pub local_models: Vec<String>,
    pub port: u16,
    pub management_secret: String,
    /// Monotonic generation of the bytes this call left current. A forced
    /// write always advances it; the ordinary coalesced path can skip the
    /// replacement and then reports the newest generation, which may describe
    /// another writer's bytes. Any later config write — including one that
    /// lands while the management reload is in flight — makes the process-wide
    /// counter differ, so a caller that did replace the file can tell that its
    /// snapshot is no longer the newest one.
    pub generation: u64,
}

/// Incremented under [`CONFIG_GENERATION_LOCK`] every time `config.yaml` is
/// actually replaced. It is not a revision of the engine's view: it only orders
/// local writes, which is what a publication needs to detect a competing save.
static CONFIG_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Serialises a generation check with the file replacement that invalidates it.
/// A publisher holds this guard across "is this generation still current?" and
/// the acknowledgement; a writer holds it from the rename until the counter
/// bump. Without it a save can replace the file between the check and the
/// acknowledgement, and the revision is marked synced for bytes that are
/// already gone.
static CONFIG_GENERATION_LOCK: Mutex<()> = Mutex::new(());

/// Held while a publication checks its generation and records the revision as
/// synced, or while a config writer replaces the file and bumps the counter.
///
/// Lock order: a config writer takes `last_written_config`, any settings lock
/// needed to render the document, and only then this guard. A publisher takes
/// this guard alone and must not acquire a settings or lifecycle lock while
/// holding it; `mark_synced` is an atomic and is safe. Never start or join a
/// config writer while holding it: that writer needs `last_written_config`
/// first, and the reverse order deadlocks.
pub struct ConfigGenerationGuard<'a> {
    _guard: MutexGuard<'a, ()>,
}

/// Blocks until no config writer is between the file replacement and the
/// generation bump, and until no publisher is acknowledging a generation.
pub fn lock_config_generation() -> ConfigGenerationGuard<'static> {
    ConfigGenerationGuard {
        _guard: CONFIG_GENERATION_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()),
    }
}

impl ConfigGenerationGuard<'_> {
    /// True when no local writer has replaced the file since `generation` was
    /// observed. Writes performed by another process (the engine normalizing the
    /// body it was sent, a manual edit) do not bump the counter and are not
    /// covered by this answer.
    pub fn is_current(&self, generation: u64) -> bool {
        config_generation() == generation
    }
}

/// The newest locally written config generation. A publication records the
/// exact generation its own write produced and checks it again around the
/// management reload: equality proves that no other local writer replaced the
/// file in that window, inequality means its snapshot is stale. External
/// writes do not participate; see [`ConfigGenerationGuard`].
pub fn config_generation() -> u64 {
    CONFIG_GENERATION.load(Ordering::Acquire)
}

/// Explicit local publication must reach the engine even when the YAML is
/// byte-identical to the last generation: a reload the engine did not
/// acknowledge is exactly the failure a retry has to repair, and the
/// idempotent path would suppress it as "nothing changed". Settings saves and
/// catalogue refreshes keep the ordinary coalesced path.
#[cfg(test)]
pub fn write_config_forced(settings: &Settings) -> Result<ConfigPublication, String> {
    write_config_from(|| settings.clone(), true)
}

/// Forced counterpart of [`write_config_current`]: the bytes are replaced even
/// when they match the previous generation, and the returned publication
/// describes exactly the snapshot that was rendered and saved.
pub fn write_config_current_forced<F>(load: F) -> Result<ConfigPublication, String>
where
    F: FnOnce() -> Settings,
{
    write_config_from(load, true)
}

fn write_config_from<F>(load: F, force: bool) -> Result<ConfigPublication, String>
where
    F: FnOnce() -> Settings,
{
    // The lock covers loading the settings, rendering the YAML and replacing
    // the file. Any narrower section lets two writers read the same old state
    // and the later one silently restore it after an earlier save.
    let mut written = last_written_config()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let settings = load();
    let mut publication = render_publication(&settings)?;
    let path = paths::config_path();
    let written_generation =
        write_config_if_changed_locked(&path, &publication.yaml, force, &mut written)?;
    // The generation must describe the bytes this call replaced, not whatever
    // is newest by the time the guard is released. Reading the counter after
    // the call would let a later writer race in and lend its generation to the
    // older document, defeating the publication's stale-snapshot check.
    publication.generation = written_generation.unwrap_or_else(config_generation);
    Ok(publication)
}

fn render_publication(settings: &Settings) -> Result<ConfigPublication, String> {
    // An empty key or secret would produce a config the engine rejects, and a
    // config without providers would reload an incomplete file into a running
    // gateway. Both are worse than keeping the previous config on disk.
    if settings.api_key.trim().is_empty() {
        return Err("отказ записи config.yaml: пустой API-ключ шлюза".to_string());
    }
    if settings.management_secret.trim().is_empty() {
        return Err("отказ записи config.yaml: пустой management secret".to_string());
    }
    fs::create_dir_all(paths::gateway_dir()).map_err(|e| e.to_string())?;
    fs::create_dir_all(paths::auths_dir()).map_err(|e| e.to_string())?;
    let auth_dir = paths::yaml_path(&paths::auths_dir());

    let mut yaml = base_config(
        settings.port,
        &settings.api_key,
        &auth_dir,
        &settings.management_secret,
        settings.stream_bootstrap_timeout_seconds,
        &RoutingTuning {
            affinity: settings.session_affinity,
            affinity_ttl: settings.session_affinity_ttl,
            retry: settings.request_retry,
            cooldown: settings.transient_cooldown,
            strategy: engine_strategy(&settings.gateway_strategy),
        },
    );
    yaml.push_str(&crate::plugin_settings::gateway_yaml());
    yaml.push_str(&crate::catalog::config_block());
    let (local_block, local_models) = local_api_keys_yaml(settings)?;
    yaml.push_str(&local_block);

    Ok(ConfigPublication {
        yaml,
        local_models,
        port: settings.port,
        management_secret: settings.management_secret.clone(),
        generation: 0,
    })
}

/// Last YAML this process wrote, per config path. The engine normalizes the
/// management secret and rewrites the file itself after a reload, so comparing
/// with the bytes on disk would keep restoring the plaintext version and
/// trigger a reload storm. Compare the intent instead.
fn last_written_config() -> &'static Mutex<HashMap<PathBuf, String>> {
    static LAST: OnceLock<Mutex<HashMap<PathBuf, String>>> = OnceLock::new();
    LAST.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Pure predicate behind the idempotent write: a missing file always needs a
/// write, otherwise only a changed generation counts.
fn config_needs_write(proposed: &str, last_written: Option<&str>, file_exists: bool) -> bool {
    if !file_exists {
        return true;
    }
    last_written != Some(proposed)
}

/// Writes the config only when the generated YAML differs from what this
/// process last handed to the engine. Returns whether the file was replaced.
#[cfg(test)]
fn write_config_if_changed(path: &std::path::Path, contents: &str) -> Result<bool, String> {
    write_config_if_changed_with(path, contents, false)
}

/// Same write, but a matching generation is not a reason to skip: the engine
/// may have missed the previous notification. Returns `true` whenever the file
/// was replaced.
#[cfg(test)]
fn write_config_if_changed_forced(path: &std::path::Path, contents: &str) -> Result<bool, String> {
    write_config_if_changed_with(path, contents, true)
}

#[cfg(test)]
fn write_config_if_changed_with(
    path: &std::path::Path,
    contents: &str,
    force: bool,
) -> Result<bool, String> {
    let mut written = last_written_config()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    write_config_if_changed_locked(path, contents, force, &mut written)
        .map(|generation| generation.is_some())
}

/// Caller already holds the write lock, so loading settings and replacing the
/// file cannot interleave with another config writer.
fn write_config_if_changed_locked(
    path: &std::path::Path,
    contents: &str,
    force: bool,
    written: &mut HashMap<PathBuf, String>,
) -> Result<Option<u64>, String> {
    let exists = path.exists();
    if !force && !config_needs_write(contents, written.get(path).map(String::as_str), exists) {
        return Ok(None);
    }

    // Atomic replace: a crash mid-write must not leave a broken config the
    // engine would refuse to start with.
    let tmp = paths::tmp_path(path);
    fs::write(&tmp, contents).map_err(|e| format!("could not write {}: {e}", tmp.display()))?;
    let mut last_error = String::new();
    let mut written_generation = None;
    for attempt in 0..3u64 {
        // The rename and the counter bump are one critical section. A
        // publisher holds the same guard while it checks its generation and
        // calls `mark_synced`; without this, the file can be replaced in that
        // window and the publication acknowledges bytes that are already gone.
        let generation = lock_config_generation();
        match fs::rename(&tmp, path) {
            Ok(()) => {
                written_generation = Some(CONFIG_GENERATION.fetch_add(1, Ordering::AcqRel) + 1);
                break;
            }
            Err(error) => {
                drop(generation);
                last_error = error.to_string();
                if attempt < 2 {
                    std::thread::sleep(Duration::from_millis(50 * (attempt + 1)));
                }
            }
        }
    }
    let Some(written_generation) = written_generation else {
        // Never truncate the live file in place: a partial write while the
        // engine reads it is worse than a skipped reload, and the old config
        // must survive a transient sharing violation. The explicit publication
        // retry (forced write) replaces it once the handle is released.
        let _ = fs::remove_file(&tmp);
        return Err(format!(
            "could not replace {}: {last_error}",
            path.display()
        ));
    };
    written.insert(path.to_path_buf(), contents.to_string());
    eprintln!("[gateway] config.yaml written ({} bytes)", contents.len());
    Ok(Some(written_generation))
}

/// Test-only access to the production replacement primitive without touching
/// the user's config path. The returned generation names the bytes this call
/// actually put on disk.
#[cfg(test)]
pub(crate) fn write_config_for_test(
    path: &std::path::Path,
    contents: &str,
    force: bool,
) -> Result<Option<u64>, String> {
    let mut written = HashMap::new();
    write_config_if_changed_locked(path, contents, force, &mut written)
}

/// Coalesces a burst of config changes (settings, catalogue refresh, local
/// routes) into one engine reload instead of one per caller.
pub fn schedule_write_config<F>(load: F)
where
    F: FnOnce() -> Settings + Send + 'static,
{
    static GENERATION: AtomicU64 = AtomicU64::new(0);
    let generation = GENERATION.fetch_add(1, Ordering::Relaxed) + 1;
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(350)).await;
        // A newer change superseded this one; it will read and write the latest
        // state itself. The callback deliberately loads the settings only after
        // the delay: an eagerly captured snapshot would restore values that a
        // save performed during the sleep already replaced.
        if GENERATION.load(Ordering::Relaxed) != generation {
            return;
        }
        if let Err(error) = write_config_current(load) {
            eprintln!("[gateway] config write failed: {error}");
        }
    });
}

/// The fixed part of config.yaml. `secret` is the plaintext management secret:
/// the engine bcrypt-hashes it on load and every management call authenticates
/// with the plaintext value.
pub(crate) struct RoutingTuning {
    pub affinity: bool,
    pub affinity_ttl: u32,
    pub retry: u32,
    pub cooldown: u32,
    pub strategy: &'static str,
}

/// The engine spelling of the gateway strategy. `weighted` is the default the
/// macOS app falls back to, so an unknown value must not reach the config.
pub(crate) fn engine_strategy(value: &str) -> &'static str {
    match value {
        "roundRobin" => "round-robin",
        "fillFirst" => "fill-first",
        _ => "weighted-round-robin",
    }
}

fn base_config(
    port: u16,
    api_key: &str,
    auth_dir: &str,
    secret: &str,
    stream_bootstrap_timeout_seconds: i64,
    tuning: &RoutingTuning,
) -> String {
    // Canonical v8 layout. `PUT /v0/management/config.yaml` accepted the legacy
    // spelling and silently rewrote it, while `PUT /v8/management/config.yaml`
    // rejects every legacy root, so the file the engine stores and the file we
    // send back on reload have to use the same names.
    format!(
        r#"# Melon Tools — Codex API gateway config (CLIProxyAPI)
config-version: 8
# Read by the QoS patch (MacOS/patches/0001): first-token failover for
# streaming Antigravity requests. v8 accepts it because the same patch adds it
# to the v8 root allowlist.
stream-bootstrap-timeout-seconds: {stream_bootstrap_timeout_seconds}
server:
  host: "127.0.0.1"
  port: {port}
access:
  api-keys:
    - "{api_key}"
oauth:
  auth-dir: "{auth_dir}"
management:
  allow-remote: false
  secret-key: "{secret}"
  disable-control-panel: true
  disable-auto-update-panel: true
routing:
  strategy: "{strategy}"
  # Keep one conversation on one account. Without it every turn may land on a
  # different credential, which splits the upstream cache and makes a single
  # conversation look like many unrelated clients.
  session-affinity: {affinity}
  session-affinity-ttl: "{ttl}"
  session-affinity-subagents: {affinity}
  # Any failed attempt moves the conversation to another account. Binding the
  # rebind to quota errors only meant a plain 5xx or a timeout kept the session
  # pinned to a broken credential, and the same hiccup came back on the next
  # turn. With a retry budget of two the cost of moving is one extra request,
  # and the alternative is a visible 503.
  session-affinity-rebind-on: "any"
# These three are root-level fields in the engine config; nesting them under
# `routing:` makes them unreadable and silently drops the tuning. The v8 loader
# decodes with KnownFields(true), so a wrong shape is not ignored politely.
# Two attempts before the client sees a failure. A single retry turned any
# upstream hiccup into a 503, because the first failing account was also the
# only one tried. The second attempt lands on a different account and the third
# covers a stale credential that still looked healthy inside the cooldown window.
request-retry: {retry}
max-retry-interval: 30
transient-error-cooldown-seconds: {cooldown}
requests:
  proxy-url: "{proxy}"
"#,
        port = port,
        api_key = yaml_escape(api_key),
        auth_dir = auth_dir,
        secret = yaml_escape(secret),
        proxy = yaml_escape(&crate::proxy::engine_url()),
        stream_bootstrap_timeout_seconds = stream_bootstrap_timeout_seconds.max(0),
        affinity = tuning.affinity,
        ttl = format_affinity_ttl(tuning.affinity_ttl),
        retry = tuning.retry.min(5),
        cooldown = tuning.cooldown.min(600),
        strategy = tuning.strategy,
    )
}

/// Claude model catalogue for the API-key fallback: raw Anthropic ids used as
/// both `name` and `alias`, so the engine lists slash-less `claude-*` ids.
pub(crate) const CLAUDE_MODELS: &[(&str, &str)] = &[
    ("claude-opus-5-5", "Claude Opus 5.5"),
    ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
    ("claude-opus-4-6", "Claude Opus 4.6"),
    ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
    ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
];

/// Version-carrying User-Agent for managed upstreams (D2): derived from the
/// crate version so a release never advertises a stale build.
pub(crate) const USER_AGENT: &str = concat!("MelonTools/", env!("CARGO_PKG_VERSION"));

/// The single optional top-level `api-keys:` root. OpenCode and OpenRouter
/// ride `openai-compatibility`; the Anthropic API-key fallback rides `claude`.
/// Every section is emitted from this one builder — a second root would break
/// the engine config. Returns an empty string when nothing is configured.
#[cfg(test)]
pub fn api_keys_yaml(settings: &Settings) -> String {
    // Tests never depend on the stored groups file: an unreadable store yields
    // an empty config rather than a test that changes with the developer's
    // appdata. The store failure itself is covered in routing_groups tests.
    local_api_keys_yaml(settings)
        .map(|(yaml, _)| yaml)
        .unwrap_or_default()
}

/// Same builder, but the local alias list comes from the very snapshot the
/// YAML was rendered from. A publication that promises a different set than
/// the file declares can never converge.
fn local_api_keys_yaml(settings: &Settings) -> Result<(String, Vec<String>), String> {
    let local_models = servable_local_models();
    // The relay, not the router: it forwards every call and merges the model's
    // system prompt into the request body on the way through. Only started when
    // a local model is actually served — a config write with no local models
    // has no business binding a listener.
    let local_port = if local_models.is_empty() {
        0
    } else {
        crate::local_ai::published_local_port()
    };
    let local_token = crate::local_ai::get_or_create_internal_token();
    let aliases = local_models
        .iter()
        .map(|model| local_model_alias(&model.id))
        .collect();
    Ok((
        api_keys_yaml_with_local(settings, &local_models, local_port, &local_token)?,
        aliases,
    ))
}

/// Models the local engine is serving right now.
///
/// `Ready` is written by the runtime only after `/health` answered and is
/// rewritten to `Installed`/`Error` on stop, crash and unload, so this list
/// follows the live engine. A second `Installed || Ready` filter used to sit
/// behind the `Ready` filter and could never match anything, which is how
/// installed-but-stopped models leaked into `/v1/models` (§14.2, W6).
pub fn servable_local_models() -> Vec<crate::local_ai::LocalModel> {
    crate::local_ai::LocalModelStore::load_registry()
        .into_iter()
        .filter(|m| m.runtime_status == crate::local_ai::ModelRuntimeStatus::Ready)
        .collect()
}

pub fn local_model_alias(id: &str) -> String {
    if id.starts_with("local/") {
        id.to_string()
    } else {
        format!("local/{id}")
    }
}

pub fn api_keys_yaml_with_local(
    settings: &Settings,
    local_models: &[crate::local_ai::LocalModel],
    local_port: u16,
    local_token: &str,
) -> Result<String, String> {
    // Model groups rewrite aliases; the store is read once per config build.
    // A broken store must fail the publication: the old fallback to an empty
    // group list erased every route on the next save.
    let groups = crate::routing_groups::load()?;
    Ok(api_keys_yaml_with_groups(
        settings,
        local_models,
        local_port,
        local_token,
        &groups,
    ))
}

/// Pure variant: the same YAML for an explicit group list, so tests never
/// touch the user's stored groups.
pub(crate) fn api_keys_yaml_with_groups(
    settings: &Settings,
    local_models: &[crate::local_ai::LocalModel],
    local_port: u16,
    local_token: &str,
    groups: &[crate::routing_groups::Group],
) -> String {
    let opencode = settings.opencode_enabled && !settings.opencode_key.trim().is_empty();
    let openrouter = settings.openrouter_enabled && !settings.openrouter_key.trim().is_empty();
    let deepinfra = settings.deepinfra_enabled
        && !settings.deepinfra_key.trim().is_empty()
        && !settings.deepinfra_models.is_empty();
    let nvidia = settings.nvidia_enabled
        && !settings.nvidia_key.trim().is_empty()
        && !settings.nvidia_models.is_empty();
    let vercel = settings.vercel_enabled
        && !settings.vercel_key.trim().is_empty()
        && !settings.vercel_models.is_empty();
    let zai = settings.zai_enabled
        && !settings.zai_key.trim().is_empty()
        && !settings.zai_models.is_empty();
    let commandcode = settings.commandcode_enabled
        && !settings.commandcode_key.trim().is_empty()
        && !settings.commandcode_models.is_empty();
    let commandcode_openai: Vec<&crate::settings::ProviderModel> = settings
        .commandcode_models
        .iter()
        .filter(|model| model.anthropic_only != Some(true))
        .collect();
    let commandcode_anthropic: Vec<&crate::settings::ProviderModel> = settings
        .commandcode_models
        .iter()
        .filter(|model| model.anthropic_only == Some(true))
        .collect();
    let commandcode_openai = commandcode && !commandcode_openai.is_empty();
    let commandcode_anthropic = commandcode && !commandcode_anthropic.is_empty();
    let claude = settings.claude_enabled && !settings.claude_api_key.trim().is_empty();
    let local_ai = !local_models.is_empty();

    // Custom providers are grouped by the protocol that decides which gateway
    // section they belong to. Invalid or disabled entries are skipped here as
    // well as in the UI, so a hand-edited settings file cannot break the YAML.
    let mut custom_chat: Vec<(&crate::settings::CustomProvider, String)> = Vec::new();
    let mut custom_responses: Vec<(&crate::settings::CustomProvider, String)> = Vec::new();
    let mut custom_anthropic: Vec<(&crate::settings::CustomProvider, String)> = Vec::new();
    let mut custom_gemini: Vec<(&crate::settings::CustomProvider, String)> = Vec::new();
    for provider in &settings.custom_providers {
        if !provider.enabled || provider.api_key.trim().is_empty() {
            continue;
        }
        if crate::custom::valid_identifier(&provider.id).is_err() {
            continue;
        }
        if !provider.models.iter().any(|model| {
            let id = model.id.trim();
            !id.is_empty()
                && (model.enabled
                    || !crate::routing_groups::group_aliases_for(groups, &provider.id, id).is_empty())
        }) {
            continue;
        }
        let Ok(protocol) = crate::custom::Protocol::parse(&provider.protocol) else {
            continue;
        };
        let Ok(base_url) = crate::custom::normalize_base_url(&provider.base_url, protocol) else {
            continue;
        };
        match protocol {
            crate::custom::Protocol::OpenAIChat => custom_chat.push((provider, base_url)),
            crate::custom::Protocol::OpenAIResponses => custom_responses.push((provider, base_url)),
            crate::custom::Protocol::Anthropic => custom_anthropic.push((provider, base_url)),
            crate::custom::Protocol::Gemini => custom_gemini.push((provider, base_url)),
        }
    }
    let has_custom = !custom_chat.is_empty()
        || !custom_responses.is_empty()
        || !custom_anthropic.is_empty()
        || !custom_gemini.is_empty();

    if !opencode
        && !openrouter
        && !deepinfra
        && !nvidia
        && !vercel
        && !zai
        && !commandcode_openai
        && !claude
        && !commandcode_anthropic
        && !local_ai
        && !has_custom
    {
        return String::new();
    }

    let mut yaml = String::from("api-keys:\n");

    if opencode
        || openrouter
        || deepinfra
        || nvidia
        || vercel
        || zai
        || commandcode_openai
        || local_ai
        || !custom_chat.is_empty()
    {
        yaml.push_str("  openai-compatibility:\n");
        if local_ai {
            yaml.push_str("    - name: \"melon-local-ai\"\n");
            yaml.push_str(&format!(
                "      base-url: \"http://127.0.0.1:{}/v1\"\n",
                local_port
            ));
            // `proxy-url: direct` keeps the local engine off the user's egress
            // proxy: a SOCKS5 proxy refuses 127.0.0.1, so without this every
            // local call fails with a transport error.
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n          proxy-url: \"direct\"\n",
                yaml_escape(local_token)
            ));
            yaml.push_str("      models:\n");
            for m in local_models {
                let fallback = local_model_alias(&m.id);
                let aliases = crate::routing_groups::aliases_for(groups, "local", &m.id, &fallback);
                push_model_aliases(
                    &mut yaml,
                    &m.id,
                    &aliases,
                    (!m.display_name.trim().is_empty() && m.display_name != m.id)
                        .then(|| m.display_name.trim()),
                    (m.user_settings.context_length > 0).then_some(m.user_settings.context_length as u64),
                );
            }
        }
        if opencode {
            yaml.push_str("    - name: \"opencode-go\"\n");
            yaml.push_str("      base-url: \"https://opencode.ai/inference/go/openai/v1\"\n");
            yaml.push_str("      headers:\n");
            yaml.push_str(&format!("        user-agent: \"{}\"\n", USER_AGENT));
            yaml.push_str("        x-opencode-session: \"melon-tools\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.opencode_key)
            ));
            if settings.opencode_models.is_empty() {
                yaml.push_str("      models:\n");
                for (name, display) in OPENCODE_MODELS {
                    let fallback = format!("opencode/{name}");
                    let aliases =
                        crate::routing_groups::aliases_for(groups, "opencode", name, &fallback);
                    push_model_aliases(&mut yaml, name, &aliases, Some(display), None);
                }
            } else {
                push_cached_models(&mut yaml, "opencode", &settings.opencode_models, groups);
            }
        }
        if openrouter {
            yaml.push_str("    - name: \"openrouter\"\n");
            yaml.push_str("      base-url: \"https://openrouter.ai/api/v1\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.openrouter_key)
            ));
            push_openrouter_models(&mut yaml, settings, groups);
        }
        if deepinfra {
            yaml.push_str("    - name: \"deepinfra\"\n");
            yaml.push_str("      base-url: \"https://api.deepinfra.com/v1/openai\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.deepinfra_key)
            ));
            push_cached_models(&mut yaml, "deepinfra", &settings.deepinfra_models, groups);
        }
        if nvidia {
            yaml.push_str("    - name: \"nvidia\"\n");
            yaml.push_str("      base-url: \"https://integrate.api.nvidia.com/v1\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.nvidia_key)
            ));
            push_cached_models(&mut yaml, "nvidia", &settings.nvidia_models, groups);
        }
        if vercel {
            yaml.push_str("    - name: \"vercel\"\n");
            yaml.push_str("      base-url: \"https://ai-gateway.vercel.sh/v1\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.vercel_key)
            ));
            push_cached_models(&mut yaml, "vercel", &settings.vercel_models, groups);
        }
        if zai {
            yaml.push_str("    - name: \"zai\"\n");
            yaml.push_str(&format!(
                "      base-url: \"{}\"\n",
                crate::providers::ZAI_BASE_URL
            ));
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.zai_key)
            ));
            push_cached_models(&mut yaml, "zai", &settings.zai_models, groups);
        }
        if commandcode_openai {
            yaml.push_str("    - name: \"commandcode\"\n");
            yaml.push_str(&format!(
                "      base-url: \"{}\"\n",
                crate::providers::COMMANDCODE_BASE_URL
            ));
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.commandcode_key)
            ));
            let models: Vec<crate::settings::ProviderModel> = settings
                .commandcode_models
                .iter()
                .filter(|model| model.anthropic_only != Some(true))
                .cloned()
                .collect();
            push_cached_models(&mut yaml, "commandcode", &models, groups);
        }
        for (provider, base_url) in &custom_chat {
            push_custom_provider(&mut yaml, provider, base_url, groups);
        }
    }

    if !custom_responses.is_empty() {
        yaml.push_str("  codex:\n");
        for (provider, base_url) in &custom_responses {
            push_custom_provider(&mut yaml, provider, base_url, groups);
        }
    }

    if claude || commandcode_anthropic || !custom_anthropic.is_empty() {
        yaml.push_str("  claude:\n");
        if claude {
            yaml.push_str("    - name: \"claude\"\n");
            yaml.push_str("      base-url: \"https://api.anthropic.com\"\n");
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.claude_api_key)
            ));
            yaml.push_str("      models:\n");
            for (name, display) in CLAUDE_MODELS {
                let aliases = crate::routing_groups::aliases_for(groups, "claude", name, name);
                push_model_aliases(&mut yaml, name, &aliases, Some(display), None);
            }
        }
        if commandcode_anthropic {
            yaml.push_str("    - name: \"commandcode-anthropic\"\n");
            yaml.push_str(&format!(
                "      base-url: \"{}\"\n",
                crate::providers::COMMANDCODE_BASE_URL
            ));
            yaml.push_str(&format!(
                "      keys:\n        - api-key: \"{}\"\n",
                yaml_escape(&settings.commandcode_key)
            ));
            let models: Vec<crate::settings::ProviderModel> = settings
                .commandcode_models
                .iter()
                .filter(|model| model.anthropic_only == Some(true))
                .cloned()
                .collect();
            push_cached_models(&mut yaml, "commandcode", &models, groups);
        }
        for (provider, base_url) in &custom_anthropic {
            push_custom_provider(&mut yaml, provider, base_url, groups);
        }
    }

    if !custom_gemini.is_empty() {
        yaml.push_str("  gemini:\n");
        for (provider, base_url) in &custom_gemini {
            push_custom_provider(&mut yaml, provider, base_url, groups);
        }
    }

    if openrouter {
        append_openrouter_payload(&mut yaml, settings);
    }

    yaml
}

fn append_openrouter_payload(yaml: &mut String, settings: &Settings) {
    let config = &settings.openrouter_config;
    let has_models = settings
        .openrouter_models
        .iter()
        .any(|model| !model.id.trim().is_empty());
    if !has_models {
        return;
    }
    yaml.push_str("\npayload:\n  default-raw:\n");
    for model in settings
        .openrouter_models
        .iter()
        .filter(|model| !model.id.trim().is_empty())
    {
        let strategy = config
            .models
            .get(&model.id)
            .map(String::as_str)
            .unwrap_or(config.default_strategy.as_str());
        let model_config = config.model_providers.get(&model.id);
        let sort = match strategy {
            "throughput" | "nitro" => "throughput",
            "latency" => "latency",
            _ => "price",
        };
        let mut provider = serde_json::Map::new();
        provider.insert("sort".to_string(), json!(sort));
        provider.insert("data_collection".to_string(), json!(config.data_collection));
        provider.insert(
            "require_parameters".to_string(),
            json!(config.require_parameters),
        );
        provider.insert(
            "allow_fallbacks".to_string(),
            json!(model_config
                .and_then(|value| value.allow_fallbacks)
                .unwrap_or(config.allow_fallbacks)),
        );
        for (key, values) in [
            (
                "order",
                model_config
                    .map(|value| &value.order)
                    .filter(|values| !values.is_empty())
                    .unwrap_or(&config.order),
            ),
            (
                "only",
                model_config
                    .map(|value| &value.only)
                    .filter(|values| !values.is_empty())
                    .unwrap_or(&config.only),
            ),
            (
                "ignore",
                model_config
                    .map(|value| &value.ignore)
                    .filter(|values| !values.is_empty())
                    .unwrap_or(&config.ignore),
            ),
        ] {
            if !values.is_empty() {
                provider.insert(key.to_string(), json!(values));
            }
        }
        if !config.quantizations.is_empty() {
            provider.insert("quantizations".to_string(), json!(config.quantizations));
        }
        let provider_json =
            serde_json::to_string(&Value::Object(provider)).unwrap_or_else(|_| "{}".to_string());
        let escaped = provider_json.replace('\\', "\\\\").replace('"', "\\\"");
        yaml.push_str(&format!(
            "    - models:\n        - name: \"{}\"\n          protocol: \"openai\"\n      params:\n        provider: \"{}\"\n",
            yaml_escape(&format!("openrouter/{}", model.id)), escaped
        ));
    }
}

/// One model name with every alias that reaches it: the ordinary provider
/// alias first, then each active group. Metadata is written on every entry so
/// the engine catalog shows the same display name and context for each alias.
fn push_model_aliases(
    yaml: &mut String,
    name: &str,
    aliases: &[String],
    display: Option<&str>,
    context: Option<u64>,
) {
    for alias in aliases {
        yaml.push_str(&format!(
            "        - name: \"{}\"\n          alias: \"{}\"\n",
            yaml_escape(name),
            yaml_escape(alias)
        ));
        if let Some(display) = display {
            yaml.push_str(&format!(
                "          display-name: \"{}\"\n",
                yaml_escape(display)
            ));
        }
        if let Some(context) = context {
            yaml.push_str(&format!("          max-context-length: {context}\n"));
        }
    }
}

fn push_openrouter_models(
    yaml: &mut String,
    settings: &Settings,
    groups: &[crate::routing_groups::Group],
) {
    if settings.openrouter_models.is_empty() {
        return;
    }
    yaml.push_str("      models:\n");
    for model in &settings.openrouter_models {
        let strategy = settings
            .openrouter_config
            .models
            .get(&model.id)
            .map(String::as_str)
            .unwrap_or(settings.openrouter_config.default_strategy.as_str());
        let upstream = match strategy {
            "floor" | "nitro" if !model.id.ends_with(&format!(":{}", strategy)) => {
                format!("{}:{}", model.id, strategy)
            }
            _ => model.id.clone(),
        };
        let fallback = format!("openrouter/{}", model.id);
        let aliases =
            crate::routing_groups::aliases_for(groups, "openrouter", &model.id, &fallback);
        push_model_aliases(
            yaml,
            &upstream,
            &aliases,
            (!model.display.trim().is_empty()).then(|| model.display.trim()),
            model.context_window.filter(|value| *value > 0),
        );
    }
}

/// Explicit model list for a cached provider. The gateway must never discover
/// unfiltered upstream models when a key is configured.
/// One custom provider entry. The alias is recomputed from the provider id so
/// renaming a provider cannot leave stale aliases in the config.
fn push_custom_provider(
    yaml: &mut String,
    provider: &crate::settings::CustomProvider,
    base_url: &str,
    groups: &[crate::routing_groups::Group],
) {
    yaml.push_str(&format!(
        "    - name: \"{}\"\n      base-url: \"{}\"\n",
        yaml_escape(&provider.id),
        yaml_escape(base_url),
    ));
    // Selection tier, emitted only when set: zero is the engine's "no
    // preference" and writing it out would just be noise in the config.
    if let Some(priority) = provider.priority.filter(|value| *value != 0) {
        yaml.push_str(&format!("      priority: {priority}\n"));
    }
    // Applied after the engine's user-agent default, so a value here wins.
    // A provider behind Cloudflare refuses the default `Go-http-client`.
    let headers: std::collections::BTreeMap<String, String> = if provider.headers.is_empty() {
        crate::providers::default_headers()
    } else {
        provider.headers.clone()
    };
    if !headers.is_empty() {
        yaml.push_str("      headers:\n");
        for (name, value) in &headers {
            yaml.push_str(&format!(
                "        {}: \"{}\"\n",
                yaml_escape(name),
                yaml_escape(value),
            ));
        }
    }
    yaml.push_str(&format!(
        "      keys:\n        - api-key: \"{}\"\n",
        yaml_escape(provider.api_key.trim()),
    ));
    yaml.push_str("      models:\n");
    for model in &provider.models {
        let id = model.id.trim();
        if id.is_empty() {
            continue;
        }
        // A disabled model may still be a group member: the group alias is
        // then its only route, so the ordinary provider alias stays hidden.
        let aliases = if model.enabled {
            let fallback = crate::custom::model_alias(&provider.id, id);
            crate::routing_groups::aliases_for(groups, &provider.id, id, &fallback)
        } else {
            crate::routing_groups::group_aliases_for(groups, &provider.id, id)
        };
        if aliases.is_empty() {
            continue;
        }
        let display = model.display.trim();
        push_model_aliases(
            yaml,
            id,
            &aliases,
            (!display.is_empty() && display != id).then_some(display),
            model.context_window.filter(|value| *value > 0),
        );
    }
}

fn push_cached_models(
    yaml: &mut String,
    provider: &str,
    models: &[crate::settings::ProviderModel],
    groups: &[crate::routing_groups::Group],
) {
    yaml.push_str("      models:\n");
    for model in models {
        let fallback = format!("{provider}/{}", model.id);
        let aliases = crate::routing_groups::aliases_for(groups, provider, &model.id, &fallback);
        push_model_aliases(
            yaml,
            &model.id,
            &aliases,
            (!model.display.trim().is_empty()).then(|| model.display.trim()),
            model.context_window.filter(|value| *value > 0),
        );
    }
}

/// Engine affinity TTL is a duration string, not a number of seconds.
pub(crate) fn format_affinity_ttl(seconds: u32) -> String {
    let seconds = seconds.max(30);
    if seconds.is_multiple_of(3600) {
        format!("{}h", seconds / 3600)
    } else if seconds.is_multiple_of(60) {
        format!("{}m", seconds / 60)
    } else {
        format!("{seconds}s")
    }
}

/// YAML values are double-quoted: escape the quote and the backslash, and drop
/// control characters (a pasted key must not break the config).
pub(crate) fn yaml_escape(value: &str) -> String {
    value
        .chars()
        .filter(|c| !c.is_control())
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            other => vec![other],
        })
        .collect()
}

// MARK: - Auth files

pub fn auth_file_name(account: &Account, index: usize) -> String {
    let email: String = account
        .email
        .clone()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            // An account without an email must still get a stable gateway
            // filename. The index is derived from the routing order in one
            // caller and from the vault order in another, so using it here
            // would make the live PATCH lookup miss the file.
            let id: String = account
                .id
                .chars()
                .filter(|c| c.is_ascii_alphanumeric())
                .take(12)
                .collect();
            if id.is_empty() {
                format!("account{}", index)
            } else {
                format!("account-{}", id)
            }
        })
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || "@._-".contains(*c))
        .collect();
    let account_id = account
        .account_id
        .clone()
        .or_else(|| account.tokens.account_id.clone())
        .unwrap_or_default();
    let short: String = account_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(8)
        .collect();
    if short.is_empty() {
        format!("codex-{}.json", email)
    } else {
        format!("codex-{}-{}.json", email, short)
    }
}

/// Gateway priority encodes the pool *tier*, not the position inside it: the
/// engine always serves the highest ready tier first and only then balances
/// inside that tier, so equal values are what let the load rotate. Regular
/// accounts share the top tier, backups the one below. This mirrors the macOS
/// sync contract.
fn priority_for(tier: usize) -> usize {
    match tier {
        PRIORITY_TIER_BACKUP => 1,
        _ => 2,
    }
}

/// Tier constants shared with the macOS planner (`backupPriority` /
/// `regularPriority`).
const PRIORITY_TIER_BACKUP: usize = 1;

/// Smooth-weighted-round-robin share for one account, derived from the quota
/// it has left. The engine reads `weight` verbatim, so keeping this a pure
/// function of the cached reading is enough: every quota refresh re-runs the
/// sync and rewrites the auth file.
///
/// `remaining / 10` floors a full account to 10 and a nearly empty one to 0,
/// and the `max(1, …)` floor keeps the last percent routable — an exhausted
/// window is excluded by `disabled`, not by a zero weight, which would
/// silently drop the account out of the picker.
fn quota_weight(account: &Account) -> u64 {
    let hourly = account
        .quota
        .as_ref()
        .and_then(|q| q.hourly_remaining_percent)
        .unwrap_or(100.0);
    let weekly = account
        .quota
        .as_ref()
        .and_then(|q| q.weekly_remaining_percent)
        .unwrap_or(100.0);
    let remaining = hourly.min(weekly).clamp(0.0, 100.0);
    std::cmp::max(1, (remaining / 10.0) as u64)
}

/// Auth-file payload for one account: credentials, routing priority and the
/// visible pool models the account must not receive. `excluded_models` is
/// omitted for a full selection, so those files keep the older shape.
fn auth_payload(account: &Account, priority: usize, pool: &HashSet<String>) -> Value {
    let expired = account
        .tokens
        .access_expiry_unix()
        .and_then(|ts| chrono::DateTime::from_timestamp(ts as i64, 0))
        .map(|dt| dt.to_rfc3339())
        .unwrap_or_default();
    let account_id = account
        .account_id
        .clone()
        .or_else(|| account.tokens.account_id.clone())
        .unwrap_or_default();

    let mut payload = json!({
        "id_token": account.tokens.id_token.clone().unwrap_or_default(),
        "access_token": account.tokens.access_token.clone().unwrap_or_default(),
        "refresh_token": account.tokens.refresh_token.clone().unwrap_or_default(),
        "account_id": account_id,
        "last_refresh": account.last_refresh.clone().unwrap_or_else(|| chrono::Utc::now().to_rfc3339()),
        "email": account.email.clone().unwrap_or_default(),
        "type": "codex",
        "expired": expired,
        "plan_type": account.plan_type.clone().unwrap_or_else(|| "free".to_string()),
        "priority": priority,
        // Explicit weight so the weighted strategy has a share to read from
        // the auth file instead of relying on the engine default. The share
        // follows the quota left, so an account with 90% left drains ten times
        // faster than one with 9% left instead of both taking equal traffic.
        "weight": quota_weight(account),
    });
    // The engine routes a pool model only to accounts that allow it. An empty
    // exclusion list is omitted, not written as `[]`.
    let excluded = crate::codex_route::excluded_models_for(account, pool);
    if !excluded.is_empty() {
        payload["excluded_models"] = json!(excluded);
    }
    if account.is_blocked() {
        payload["disabled"] = json!(true);
    }
    payload
}

/// Whether the auths directory contains files this app owns. The state of an
/// unreadable directory is unknown, so the caller must fail closed instead of
/// treating it as empty.
fn owns_auth_files(dir: &std::path::Path) -> Result<bool, String> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(format!(
                "cannot inspect auth directory {}: {error}",
                dir.display()
            ))
        }
    };
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                return Err(format!("cannot read an auth directory entry: {error}"));
            }
        };
        if crate::claude::is_codex_auth_file_name(&entry.file_name().to_string_lossy()) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Mirrors the macOS sync: the auths directory is replaced with the current
/// vault, ordered by the routing planner (strategy + manual order + roles),
/// and accounts the planner paused (window exhausted or below the user's
/// reserve) get `"disabled": true`.
pub fn sync_accounts(settings: &Settings) -> Result<usize, String> {
    let dir = paths::auths_dir();
    // Destructive part of the sync deletes auth files that are absent from the
    // vault. Only a snapshot where every account was read and deserialized may
    // authorize that. A missing file is allowed to be an empty vault only when
    // no owned auth file exists: otherwise the file may have been lost and the
    // credentials must stay untouched.
    let accounts = match vault::verified_accounts() {
        Some(accounts) => accounts,
        None if !vault::file_exists() && !owns_auth_files(&dir)? => return Ok(0),
        None => {
            return Err(
                "отказ синхронизации auth: vault accounts.json прочитан не полностью, файлы auth не изменены"
                    .to_string(),
            )
        }
    };
    let (ordered_ids, _) = crate::routing::resolve(
        &accounts,
        &settings.routing_strategy,
        &settings.priority_order,
    );
    let mut ordered: Vec<Account> = Vec::new();
    for id in &ordered_ids {
        if let Some(account) = accounts.iter().find(|a| &a.id == id) {
            ordered.push(account.clone());
        }
    }
    // Keep excluded accounts registered for management/quota reads, but never
    // as routing candidates. Their auth payload always carries disabled=true.
    ordered.extend(accounts.iter().filter(|a| !a.pool_enabled()).cloned());
    // One pool snapshot per sync: every account is filtered against the same
    // visible set, so a quota-only sync does not read the cache twice.
    let pool = crate::codex_route::visible_pool_slugs();

    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut desired = Vec::new();
    for (index, account) in ordered.iter().enumerate() {
        let has_access = account
            .tokens
            .access_token
            .as_deref()
            .is_some_and(|token| !token.is_empty());
        if !has_access {
            continue;
        }

        let tier = if account.is_backup.unwrap_or(false) {
            PRIORITY_TIER_BACKUP
        } else {
            0
        };
        let payload = auth_payload(account, priority_for(tier), &pool);
        desired.push((
            dir.join(auth_file_name(account, index)),
            payload,
            account.pool_enabled.is_none()
                && account.quota_block.is_none()
                && !crate::routing::quota_is_fresh(account),
        ));
    }

    sync_auth_files(&dir, desired)
}

/// Write every desired auth file first, then remove the stale ones. Deleting
/// first meant a failed write left the pool with fewer credentials than before
/// the sync; now a failure keeps every old route in place.
fn sync_auth_files(
    dir: &std::path::Path,
    desired: Vec<(std::path::PathBuf, Value, bool)>,
) -> Result<usize, String> {
    let desired_names: std::collections::HashSet<String> = desired
        .iter()
        .filter_map(|(path, _, _)| {
            path.file_name()
                .map(|name| name.to_string_lossy().to_string())
        })
        .collect();
    let mut written = 0usize;
    for (file, mut payload, preserve_legacy_pause) in desired {
        let bytes = match fs::read(&file) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => {
                return Err(format!(
                    "cannot read existing auth file {}: {error}",
                    file.display()
                ));
            }
        };
        let mut current = if bytes.is_empty() {
            None
        } else {
            Some(serde_json::from_slice::<Value>(&bytes).map_err(|error| {
                format!("corrupt auth file {}: {error}", file.display())
            })?)
        };
        if let Some(Value::Object(object)) = current.as_mut() {
            if object.get("disabled").and_then(Value::as_bool) == Some(false) {
                object.remove("disabled");
            }
        }
        if preserve_legacy_pause
            && current
                .as_ref()
                .and_then(|value| value.get("disabled"))
                .and_then(Value::as_bool)
                == Some(true)
        {
            payload["disabled"] = json!(true);
        }
        if current.as_ref() == Some(&payload) {
            written += 1;
            continue;
        }
        let encoded = serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?;
        // MoveFileExW on Windows and rename on Unix: the engine must never
        // hot-reload a half-written auth file, and an existing file must be
        // replaced rather than rejected.
        crate::agents::write_atomic(&file, &encoded)?;
        written += 1;
    }

    // Only the files this sync owns are pruned: engine-written auth files of
    // other providers (claude-*.json) must survive an account sync. A stale
    // file is a route the engine keeps serving, so a directory listing or a
    // removal that fails must reach the caller: reporting success here left
    // the old credentials active with no sign of the problem.
    let entries = fs::read_dir(dir)
        .map_err(|error| format!("cannot read auth directory {}: {error}", dir.display()))?;
    let mut failures: Vec<String> = Vec::new();
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                failures.push(format!("cannot read an auth directory entry: {error}"));
                continue;
            }
        };
        let name = entry.file_name().to_string_lossy().to_string();
        if !crate::claude::is_codex_auth_file_name(&name) || desired_names.contains(&name) {
            continue;
        }
        let path = entry.path();
        if let Err(error) = fs::remove_file(&path) {
            failures.push(format!(
                "cannot remove stale auth file {}: {error}",
                path.display()
            ));
        }
    }
    if !failures.is_empty() {
        return Err(format!("auth sync left stale credentials: {}", failures.join("; ")));
    }
    Ok(written)
}

#[derive(Clone, Debug, Default)]
pub struct ManagementAuthFile {
    pub name: String,
    pub auth_index: Option<String>,
    pub disabled: bool,
    pub email: Option<String>,
    pub provider: Option<String>,
    pub observed_at: Option<String>,
    pub signals: HashMap<String, String>,
}

#[derive(Clone, Debug, Default)]
pub struct ManagementAuthSnapshot {
    pub files: Vec<ManagementAuthFile>,
}

impl ManagementAuthSnapshot {
    pub fn codex_files(&self) -> Vec<&ManagementAuthFile> {
        self.files
            .iter()
            .filter(|file| {
                file.provider
                    .as_deref()
                    .map(str::to_ascii_lowercase)
                    .as_deref()
                    == Some("codex")
                    || file.name.starts_with("codex-")
            })
            .collect()
    }
}

/// GET the live auth-file observations. This endpoint is polled by the
/// quota guard while the gateway runs; keep its timeout short.
pub async fn management_auth_files(settings: &Settings) -> Result<ManagementAuthSnapshot, String> {
    let client = gateway_client().ok_or_else(|| "management client unavailable".to_string())?;
    let response = client
        .get(format!(
            "http://127.0.0.1:{}/v0/management/auth-files",
            settings.port
        ))
        .header(
            "Authorization",
            format!("Bearer {}", settings.management_secret),
        )
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("management auth-files {}", status.as_u16()));
    }
    let value: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let observed_at = value
        .get("observed_at")
        .and_then(Value::as_str)
        .map(String::from);
    let files = value
        .get("files")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let name = entry.get("name")?.as_str()?.to_string();
            let quota = entry.get("quota");
            let signals = quota
                .and_then(|quota| quota.get("signals"))
                .and_then(Value::as_object)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(|(key, value)| {
                            value.as_str().map(|s| (key.clone(), s.to_string()))
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(ManagementAuthFile {
                name,
                auth_index: entry
                    .get("auth_index")
                    .and_then(Value::as_str)
                    .map(String::from),
                disabled: entry
                    .get("disabled")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                email: entry.get("email").and_then(Value::as_str).map(String::from),
                provider: entry
                    .get("provider")
                    .and_then(Value::as_str)
                    .map(String::from),
                observed_at: quota
                    .and_then(|quota| quota.get("observed_at"))
                    .and_then(Value::as_str)
                    .map(String::from)
                    .or_else(|| observed_at.clone()),
                signals,
            })
        })
        .collect();
    Ok(ManagementAuthSnapshot { files })
}

/// PATCH one auth status and verify it through the management read API.
pub async fn set_auth_disabled(
    settings: &Settings,
    file: &ManagementAuthFile,
    disabled: bool,
) -> bool {
    let Some(client) = gateway_client() else {
        return false;
    };
    let mut body = json!({"name": file.name, "disabled": disabled});
    if let Some(index) = &file.auth_index {
        body["auth_index"] = json!(index);
    }
    let response = client
        .patch(format!(
            "http://127.0.0.1:{}/v0/management/auth-files/status",
            settings.port
        ))
        .header(
            "Authorization",
            format!("Bearer {}", settings.management_secret),
        )
        .json(&body)
        .send()
        .await;
    if !matches!(response, Ok(ref response) if response.status().is_success()) {
        return false;
    }
    let Ok(snapshot) = management_auth_files(settings).await else {
        return false;
    };
    snapshot
        .files
        .iter()
        .find(|candidate| {
            file.auth_index
                .as_deref()
                .is_some_and(|index| candidate.auth_index.as_deref() == Some(index))
                || candidate.name == file.name
        })
        .is_some_and(|candidate| candidate.disabled == disabled)
}

// MARK: - Lifecycle

pub async fn health(port: u16, api_key: &str) -> bool {
    let Some(client) = gateway_client() else {
        return false;
    };
    match client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
    {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

/// Whether something accepts TCP connections on the gateway's loopback port.
///
/// A publication checks this before replacing `config.yaml`: a stopped gateway
/// must not cause a stream of forced writes. This is deliberately only a
/// transport probe. Querying an authenticated HTTP route would turn an API-key
/// mismatch into repeated credential failures (the engine bans the loopback
/// address after five), and a key change must still be publishable. A port held
/// by an unrelated process is indistinguishable here; the reload that follows
/// reports that case. The connect is bounded at 200 ms so a supervisor tick
/// cannot stall on a port that drops packets instead of refusing them.
pub fn is_listening_blocking(port: u16) -> bool {
    let address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    std::net::TcpStream::connect_timeout(&address, Duration::from_millis(200)).is_ok()
}

/// Async form of [`is_listening_blocking`] for the publication task.
pub async fn is_listening(port: u16) -> bool {
    tokio::task::spawn_blocking(move || is_listening_blocking(port))
        .await
        .unwrap_or(false)
}

/// Whether an adopted process still has the identity now on disk. `answers` is
/// a fresh health check performed with the current identity; it only matters
/// when the port or key changed. A changed management secret is not observable
/// through health, so it always forces a restart.
fn adopt_matches(probed: &Settings, current: &Settings, answers: bool) -> bool {
    current.management_secret == probed.management_secret
        && ((current.port == probed.port && current.api_key == probed.api_key) || answers)
}

pub async fn start<F>(gateway: &Gateway, load: F) -> Result<String, String>
where
    F: Fn() -> Settings,
{
    rotate_log(&paths::log_path());
    // Complete the engine catalog before the config points at it: the engine
    // refuses a `models.catalog` path it cannot read. Bounded so an
    // unreachable host never holds the gateway down.
    //
    // The refresh can take seconds, and settings saves are allowed meanwhile.
    // Every use after the await loads the live settings again: writing the
    // snapshot taken before the refresh would put the old port/key/provider
    // set back on disk and the engine would start from it.
    let _ = crate::catalog::refresh_for_start().await;
    let settings = load();
    if health(settings.port, &settings.api_key).await {
        write_config_current(&load)?;
        let current = load();
        // The probe above used the snapshot from before the write. A save can
        // change the port, key or management secret while it runs; adopting
        // then would keep a process the new config cannot authenticate
        // against. Re-probe the new identity; a changed secret cannot be
        // proven over the public health endpoint, so it forces a restart.
        let identity_changed = current.port != settings.port
            || current.api_key != settings.api_key
            || current.management_secret != settings.management_secret;
        let answers = if identity_changed {
            health(current.port, &current.api_key).await
        } else {
            true
        };
        if adopt_matches(&settings, &current, answers) {
            sync_accounts(&current)?;
            #[cfg(windows)]
            adopt_recorded_engine()?;
            gateway.mark_running();
            return Ok("adopted".to_string());
        }
    }

    write_config_current(&load)?;
    let current = load();
    sync_accounts(&current)?;

    // A wedged child (alive but not answering health) would hold the port:
    // terminate it before spawning a fresh engine, otherwise the retry path
    // accumulates engines that can never bind.
    if let Ok(mut guard) = gateway.child.lock() {
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    #[cfg(windows)]
    if let Some(pid) = fs::read_to_string(paths::pid_path())
        .ok()
        .as_deref()
        .and_then(parse_pid)
    {
        stop_recorded_pid(pid);
    }

    let binary = resolve_sidecar_checked()?;

    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths::log_path())
        .map_err(|e| e.to_string())?;
    let log_err = log.try_clone().map_err(|e| e.to_string())?;

    let mut command = Command::new(&binary);
    command
        .arg("-config")
        .arg(paths::config_path())
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));
    create_no_window(&mut command);

    #[allow(unused_mut)]
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    let pid = child.id();
    #[cfg(windows)]
    if let Err(error) = crate::engine_job::assign(pid) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!(
            "Cannot contain the gateway process safely: {error}"
        ));
    }
    if let Ok(mut guard) = gateway.child.lock() {
        *guard = Some(child);
    }
    gateway.mark_running();
    let _ = fs::write(paths::pid_path(), pid.to_string());
    // Count the new process now, not after the health poll: a slow engine that
    // is adopted by a later `start` is still a different process from the one
    // whose credential the ban describes. Adoption of a pre-existing engine
    // returns above and never reaches this line.
    gateway.started_generation.fetch_add(1, Ordering::AcqRel);

    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let probe = load();
        if health(probe.port, &probe.api_key).await {
            return Ok("started".to_string());
        }
    }
    Err("шлюз не ответил за 15 секунд — смотрите gateway.log".to_string())
}

pub fn stop(gateway: &Gateway) -> Result<String, String> {
    // `RunEvent::Exit`, the tray quit and the updater all arrive here, often
    // twice in the same exit. The lock serialises them and the flag turns the
    // repeat into a no-op: a second `taskkill /IM` sweep would only probe for
    // engines that are already gone (§2.2, W9).
    let mut stopped = gateway
        .stopped
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if *stopped {
        return Ok("already stopped".to_string());
    }
    if let Ok(mut guard) = gateway.child.lock() {
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    // An adopted or orphaned engine is killed by the PID we recorded when we
    // started it, and only after tasklist confirms that PID is still our
    // engine: an image-name taskkill could hit an unrelated cliproxyapi.
    let recorded = fs::read_to_string(paths::pid_path()).ok();
    match recorded.as_deref().and_then(parse_pid) {
        Some(pid) => stop_recorded_pid(pid),
        None => {
            // No usable PID record (first run of an older build): keep the
            // old image-name sweep as the only available cleanup.
            #[cfg(windows)]
            {
                for name in SIDECAR_NAMES {
                    let mut command = Command::new("taskkill");
                    command.args(["/IM", name, "/F"]);
                    create_no_window(&mut command);
                    let _ = command.output();
                }
            }
        }
    }
    let _ = fs::remove_file(paths::pid_path());
    *stopped = true;
    Ok("stopped".to_string())
}

/// PID file contents: one decimal process id (whitespace and a trailing
/// newline are tolerated). Zero is never a valid target.
pub(crate) fn parse_pid(text: &str) -> Option<u32> {
    text.trim().parse::<u32>().ok().filter(|pid| *pid != 0)
}

/// First CSV field of `tasklist /FO CSV /NH` output. The "no tasks" notice is
/// not CSV, so it yields `None` instead of a bogus image name.
#[cfg(any(windows, test))]
pub(crate) fn parse_tasklist_image(output: &str) -> Option<String> {
    let line = output
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with('"'))?;
    let name = line.trim_start_matches('"').split('"').next()?.trim();
    (!name.is_empty()).then(|| name.to_string())
}

/// PID column of `tasklist /FO CSV /NH` rows. Non-CSV output is skipped.
#[cfg(any(windows, test))]
pub(crate) fn parse_tasklist_pids(output: &str) -> Vec<u32> {
    let mut pids = Vec::new();
    for line in output
        .lines()
        .map(str::trim)
        .filter(|line| line.starts_with('"'))
    {
        let fields: Vec<&str> = line.split("\",\"").collect();
        if let Some(pid) = fields
            .get(1)
            .and_then(|field| field.trim_end_matches('"').trim().parse::<u32>().ok())
        {
            pids.push(pid);
        }
    }
    pids
}

/// Image-name identity check: tasklist may report a bare name or a path.
#[cfg(any(windows, test))]
pub(crate) fn image_starts_with(image: &str, prefix: &str) -> bool {
    let base = image.rsplit(['\\', '/']).next().unwrap_or(image).trim();
    base.to_ascii_lowercase()
        .starts_with(&prefix.to_ascii_lowercase())
}

#[cfg(any(windows, test))]
pub(crate) fn image_matches_engine(image: &str) -> bool {
    image_starts_with(image, "cliproxyapi")
}

#[cfg(windows)]
pub(crate) fn tasklist_image_name(pid: u32) -> Option<String> {
    let mut command = Command::new("tasklist.exe");
    command.args(["/FI", &format!("PID eq {}", pid), "/FO", "CSV", "/NH"]);
    create_no_window(&mut command);
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    parse_tasklist_image(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(windows)]
pub(crate) fn tasklist_pids(image: &str) -> Vec<u32> {
    let mut command = Command::new("tasklist.exe");
    command.args([
        "/FI",
        &format!("IMAGENAME eq {}", image),
        "/FO",
        "CSV",
        "/NH",
    ]);
    create_no_window(&mut command);
    match command.output() {
        Ok(output) if output.status.success() => {
            parse_tasklist_pids(&String::from_utf8_lossy(&output.stdout))
        }
        _ => Vec::new(),
    }
}

#[cfg(windows)]
pub(crate) fn taskkill_pid(pid: u32, force: bool) -> bool {
    let pid = pid.to_string();
    let mut command = Command::new("taskkill.exe");
    if force {
        command.args(["/PID", &pid, "/F"]);
    } else {
        command.args(["/PID", &pid]);
    }
    create_no_window(&mut command);
    command
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Put an engine left by an earlier Melon process into the same kill-on-close
/// job. Without this an adopted engine would survive the next crash even
/// though newly spawned engines are covered.
#[cfg(windows)]
fn adopt_recorded_engine() -> Result<(), String> {
    let Some(pid) = fs::read_to_string(paths::pid_path())
        .ok()
        .as_deref()
        .and_then(parse_pid)
    else {
        return Err(
            "A healthy gateway has no recorded owner PID; stop it before starting Melon Tools."
                .to_string(),
        );
    };
    if !tasklist_image_name(pid)
        .as_deref()
        .is_some_and(image_matches_engine)
    {
        return Err("The recorded gateway PID no longer belongs to the engine.".to_string());
    }
    if let Err(error) = crate::engine_job::assign(pid) {
        stop_recorded_pid(pid);
        return Err(format!(
            "Cannot contain the adopted gateway safely: {error}"
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn stop_recorded_pid(pid: u32) {
    let Some(image) = tasklist_image_name(pid) else {
        return;
    };
    if image_matches_engine(&image) {
        let _ = taskkill_pid(pid, true);
    }
}

#[cfg(not(windows))]
fn stop_recorded_pid(_pid: u32) {}

// MARK: - Live rate

/// POST /v1/* requests in the last 60 seconds, parsed from the gateway log
/// tail (bounded read — the log grows through the session).
pub fn requests_last_minute() -> usize {
    let text = log_tail(256 * 1024);
    let now = chrono::Local::now().naive_local();
    text.lines()
        .rev()
        .take(600)
        .filter(|line| {
            line.contains("POST") && line.contains("/v1/") && {
                match parse_timestamp(line) {
                    Some(ts) => (now - ts).num_seconds() <= 60,
                    None => false,
                }
            }
        })
        .count()
}

/// Latest `[qos]` watchdog line from the gateway log. The app uses it for the
/// Antigravity telemetry strip; no auth secret is present in these lines.
pub fn last_qos_event() -> Option<Value> {
    let text = log_tail(128 * 1024);
    for line in text.lines().rev() {
        if !line.contains("[qos]") {
            continue;
        }
        let timed_out = line.contains("first_token_timeout");
        if !timed_out && !line.contains("first_token") {
            continue;
        }
        if !line.contains("provider=antigravity") {
            continue;
        }
        let value = |key: &str| -> Option<i64> {
            let marker = format!("{key}=");
            let start = line.find(&marker)? + marker.len();
            let digits: String = line[start..]
                .chars()
                .take_while(|ch| ch.is_ascii_digit())
                .collect();
            digits.parse().ok()
        };
        let text_value = |key: &str| -> Option<String> {
            let marker = format!("{key}=");
            let start = line.find(&marker)? + marker.len();
            let token: String = line[start..]
                .chars()
                .take_while(|ch| !ch.is_whitespace() && *ch != '"')
                .collect();
            (!token.is_empty()).then_some(token)
        };
        return Some(json!({
            "timedOut": timed_out,
            "auth": text_value("auth"),
            "model": text_value("model"),
            "ttftMs": value("ttft_ms"),
            "cooldownSeconds": value("cooldown_s"),
            "strike": value("strike"),
        }));
    }
    None
}

fn parse_timestamp(line: &str) -> Option<chrono::NaiveDateTime> {
    let start = line.find('[')? + 1;
    let end = line[start..].find(']')? + start;
    chrono::NaiveDateTime::parse_from_str(&line[start..end], "%Y-%m-%d %H:%M:%S").ok()
}

// MARK: - Recent calls + models (dashboard / providers)

/// The log is rotated on gateway start once it exceeds this size: the engine is
/// restarted anyway, so the open-handle rename window is safe.
const LOG_ROTATE_BYTES: u64 = 2 * 1024 * 1024;

/// Current `gateway.log` size. The watchdog uses it to rotate a log that grew
/// during a long session without waiting for the next app launch.
pub fn log_size() -> u64 {
    fs::metadata(paths::log_path())
        .map(|metadata| metadata.len())
        .unwrap_or(0)
}

/// Keeps one backup (`gateway.log.1`). Rotation failure is ignored: the engine
/// may still hold the handle, and the next fresh start retries.
fn rotate_log(path: &std::path::Path) {
    let Ok(metadata) = fs::metadata(path) else {
        return;
    };
    if metadata.len() <= LOG_ROTATE_BYTES {
        return;
    }
    let backup = path.with_extension("log.1");
    let _ = fs::remove_file(&backup);
    let _ = fs::rename(path, &backup);
}

/// Last `cap` bytes of the log, read with a seek. The file grows throughout a
/// session, so a whole-file read here would stall every status poll.
fn log_tail(cap: usize) -> String {
    use std::io::{Read, Seek, SeekFrom};

    let path = paths::log_path();
    let Ok(metadata) = fs::metadata(&path) else {
        return String::new();
    };
    let len = metadata.len();
    let start = len.saturating_sub(cap as u64);
    let Ok(mut file) = fs::File::open(&path) else {
        return String::new();
    };
    if file.seek(SeekFrom::Start(start)).is_err() {
        return String::new();
    }
    let mut data = Vec::with_capacity((len - start) as usize);
    if file.read_to_end(&mut data).is_err() {
        return String::new();
    }
    String::from_utf8_lossy(tail_bytes(&data, start > 0)).to_string()
}

/// Drops the first, partially read line of a bounded tail.
pub(crate) fn tail_bytes(bytes: &[u8], truncated: bool) -> &[u8] {
    if !truncated {
        return bytes;
    }
    match bytes.iter().position(|byte| *byte == b'\n') {
        Some(offset) => &bytes[offset + 1..],
        None => bytes,
    }
}

/// Parse one engine access-log line. Error lines append another `| message`,
/// which must not shift the four base fields.
fn parse_recent_call(line: &str) -> Option<Value> {
    if !line.contains("\"/v1/") {
        return None;
    }
    let parts: Vec<&str> = line.split('|').map(str::trim).collect();
    if parts.len() < 4 {
        return None;
    }
    let time = line
        .find('[')
        .and_then(|start| line.find(']').map(|end| &line[start + 1..end]))
        .unwrap_or("");
    let status = parts[0].split_whitespace().last().unwrap_or("");
    let mut tokens = parts[3].split_whitespace();
    let method = tokens.next().unwrap_or("");
    let path = tokens.next().unwrap_or("").trim_matches('"');
    Some(json!({
        "time": time,
        "status": status,
        "duration": parts[1],
        "method": method,
        "path": path,
    }))
}

/// The newest gateway requests (method, path, status, duration) for the
/// dashboard "recent calls" card.
pub fn recent_calls(limit: usize) -> Value {
    let text = log_tail(512 * 1024);
    let mut calls: Vec<Value> = Vec::new();
    for line in text.lines().rev() {
        if let Some(call) = parse_recent_call(line) {
            calls.push(call);
            if calls.len() >= limit {
                break;
            }
        }
    }
    Value::Array(calls)
}

/// Parse one engine telemetry usage log line.
pub fn parse_usage_record(line: &str) -> Option<Value> {
    if !line.contains("[usage]") {
        return None;
    }
    let value = |key: &str| -> Option<i64> {
        let marker = format!("{key}=");
        let start = line.find(&marker)? + marker.len();
        let digits: String = line[start..]
            .chars()
            .take_while(|ch| ch.is_ascii_digit())
            .collect();
        digits.parse().ok()
    };
    let text_value = |key: &str| -> Option<String> {
        let marker = format!("{key}=");
        let start = line.find(&marker)? + marker.len();
        let token: String = line[start..]
            .chars()
            .take_while(|ch| !ch.is_whitespace() && *ch != '"')
            .collect();
        (!token.is_empty()).then_some(token)
    };
    let timestamp = text_value("timestamp").unwrap_or_default();
    let model = text_value("model").unwrap_or_else(|| "-".to_string());
    let provider = text_value("provider").unwrap_or_else(|| "-".to_string());
    let auth = text_value("auth").unwrap_or_else(|| "-".to_string());
    let input = value("input").unwrap_or(0);
    let output = value("output").unwrap_or(0);
    let mode = text_value("mode").unwrap_or_else(|| "chat".to_string());
    let status = value("status").unwrap_or(200);

    Some(json!({
        "timestamp": timestamp,
        "model": model,
        "provider": provider,
        "auth": auth,
        "input": input,
        "output": output,
        "mode": mode,
        "status": status,
    }))
}

/// The newest usage records parsed from `[usage]` telemetry lines.
pub fn recent_usage(limit: usize) -> Value {
    let text = log_tail(512 * 1024);
    let mut usage: Vec<Value> = Vec::new();
    for line in text.lines().rev() {
        if let Some(record) = parse_usage_record(line) {
            usage.push(record);
            if usage.len() >= limit {
                break;
            }
        }
    }
    Value::Array(usage)
}

/// The gateway's live model list (id + owner) for the providers page.
pub async fn models(port: u16, api_key: &str) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let response = response.error_for_status().map_err(|e| e.to_string())?;
    let value: Value = response.json().await.map_err(|e| e.to_string())?;
    value
        .get("data")
        .filter(|data| data.is_array())
        .cloned()
        .ok_or_else(|| "Gateway returned an invalid model catalogue".to_string())
}

/// Why `PUT /v8/management/config.yaml` did not confirm the reload.
///
/// The distinction matters outside the HTTP layer: a rejected credential is
/// counted by the engine's brute-force guard, while a refused body or an
/// unreachable port is not. Only the first one must stop the retry loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReloadFailure {
    /// 401/403 from the management API.
    Auth(String),
    /// Any other transport error, non-2xx answer or missing acknowledgement.
    Refused(String),
}

impl ReloadFailure {
    pub fn message(&self) -> &str {
        match self {
            Self::Auth(message) | Self::Refused(message) => message,
        }
    }

    pub fn is_auth(&self) -> bool {
        matches!(self, Self::Auth(_))
    }
}

impl std::fmt::Display for ReloadFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

/// The v8 handler's acknowledgement, kept separate from the HTTP call so the
/// accepted and refused bodies are testable without an engine.
///
/// `PUT /v8/management/config.yaml` answers `{"status":"ok","config-version":8}`.
/// The deprecated v0 route answered `{"changed":["config"],"ok":true}`; that
/// shape is deliberately not accepted here.
fn reload_acknowledged(text: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|value| {
            value
                .get("status")
                .and_then(|s| s.as_str())
                .map(str::to_string)
        })
        .is_some_and(|status| status == "ok")
}

/// The digest of the document the engine saved for this request.
///
/// The v8 handler hashes the bytes it wrote and reports that digest in the PUT
/// answer; `/v8/management/reload-status` reports the digest of the document the
/// runtime hook proved it applied. Equal digests prove that identical bytes were
/// applied at some point, not that this request completed: the same document may
/// already have been applied before the PUT, and a later save can move the
/// generation forward without applying these bytes. Generations also advance for
/// plugin reloads, so equality is evidence about content, not completion of this
/// request.
fn reload_digest(text: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|value| {
            value
                .get("reload-digest")
                .and_then(|v| v.as_str())
                .map(str::to_string)
        })
        .filter(|digest| !digest.is_empty())
}

/// The digest the runtime proved applied. An empty string is a valid answer
/// (nothing applied yet) and is kept distinct from a missing field, which means
/// the engine does not speak this contract at all.
fn applied_reload_digest(text: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|value| {
            value
                .get("applied-digest")
                .and_then(|v| v.as_str())
                .map(str::to_string)
        })
}

const RELOAD_STATUS_TIMEOUT: Duration = Duration::from_secs(5);
const RELOAD_STATUS_INTERVAL: Duration = Duration::from_millis(100);

/// Wait until the runtime hook has applied the exact document the save wrote.
///
/// The PUT 200 is written before `reloadConfigAfterManagementSave` runs, so
/// only this comparison says the configuration reached the service. The loop is
/// bounded: an engine that never completes the hook must fail the publication
/// instead of leaving the caller to guess from `/v1/models`, which cannot tell
/// two documents with identical aliases apart.
async fn wait_reload_applied(
    client: &reqwest::Client,
    port: u16,
    management_secret: &str,
    digest: &str,
) -> Result<(), ReloadFailure> {
    let deadline = tokio::time::Instant::now() + RELOAD_STATUS_TIMEOUT;
    loop {
        let response = client
            .get(format!(
                "http://127.0.0.1:{}/v8/management/reload-status",
                port
            ))
            .header("Authorization", format!("Bearer {}", management_secret))
            .send()
            .await
            .map_err(|e| {
                ReloadFailure::Refused(format!("the reload status could not be read: {e}"))
            })?;
        let status = response.status();
        let code = status.as_u16();
        let text = response.text().await.unwrap_or_default();
        if code == 401 || code == 403 {
            return Err(ReloadFailure::Auth(format!(
                "HTTP {} while reading the reload status: {}",
                code,
                text.chars().take(300).collect::<String>()
            )));
        }
        if !status.is_success() {
            return Err(ReloadFailure::Refused(format!(
                "the engine does not report reload completion (HTTP {}): {}",
                code,
                text.chars().take(300).collect::<String>()
            )));
        }
        let applied = applied_reload_digest(&text).ok_or_else(|| {
            ReloadFailure::Refused(format!(
                "the engine returned an unreadable reload status: {}",
                text.chars().take(300).collect::<String>()
            ))
        })?;
        if applied == digest {
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(ReloadFailure::Refused(format!(
                "the engine saved config.yaml with digest {} but did not prove it applied within {} s (applied digest: {})",
                digest,
                RELOAD_STATUS_TIMEOUT.as_secs(),
                if applied.is_empty() { "none" } else { applied.as_str() }
            )));
        }
        tokio::time::sleep(RELOAD_STATUS_INTERVAL).await;
    }
}

/// Ask the running engine to adopt exactly the config generation we wrote.
///
/// The deprecated `PUT /v0/management/config.yaml` only validates the body and
/// rewrites the file: it never calls the reload hook, so the client catalogue
/// still changes only when the filesystem watcher happens to fire. The v8
/// endpoint (`PUT /v8/management/config.yaml`) saves the same tree and then
/// calls `reloadConfigAfterManagementSaveAsync`, which applies that exact saved
/// snapshot through the runtime result hook — no fsnotify event involved.
///
/// The bytes are passed in instead of being read back from disk: a settings
/// save can replace the file between our write and this request, and the
/// engine must adopt the generation the caller is publishing, not a newer one.
///
/// The engine's own rejection text is passed through: an invalid YAML keeps the
/// previous config and the old catalogue, and the reload error is the only
/// evidence of why the new model never appeared.
pub async fn reload_config(
    port: u16,
    management_secret: &str,
    yaml: &str,
) -> Result<(), ReloadFailure> {
    if management_secret.trim().is_empty() {
        return Err(ReloadFailure::Refused(
            "the management secret is empty".to_string(),
        ));
    }
    let Some(client) = gateway_client() else {
        return Err(ReloadFailure::Refused(
            "the gateway HTTP client could not be built".to_string(),
        ));
    };
    let response = client
        .put(format!(
            "http://127.0.0.1:{}/v8/management/config.yaml",
            port
        ))
        .header("Authorization", format!("Bearer {}", management_secret))
        .header("Content-Type", "application/yaml")
        .body(yaml.to_string())
        .send()
        .await
        .map_err(|e| ReloadFailure::Refused(e.to_string()))?;
    let status = response.status();
    let code = status.as_u16();
    let text = response.text().await.unwrap_or_default();
    if !status.is_success() {
        let message = format!(
            "HTTP {}: {}",
            code,
            text.chars().take(300).collect::<String>()
        );
        // 401/403 is the engine rejecting the credential, not a transient
        // transport failure. Repeating it reaches the engine's brute-force
        // guard (five failures from one IP -> 30 minute ban), so the caller
        // has to stop and wait for a different secret instead of retrying.
        return Err(if code == 401 || code == 403 {
            ReloadFailure::Auth(message)
        } else {
            ReloadFailure::Refused(message)
        });
    }
    // A 2xx is not proof by itself: the v8 handler answers with an explicit
    // status document, and anything else means the file was stored but the
    // reload was not acknowledged.
    if !reload_acknowledged(&text) {
        return Err(ReloadFailure::Refused(format!(
            "the engine stored config.yaml without acknowledging the reload: {}",
            text.chars().take(300).collect::<String>()
        )));
    }
    let digest = reload_digest(&text).ok_or_else(|| {
        ReloadFailure::Refused(format!(
            "the engine did not report the digest of the config it saved: {}",
            text.chars().take(300).collect::<String>()
        ))
    })?;
    wait_reload_applied(client, port, management_secret, &digest).await
}

// MARK: - End-to-end check

pub async fn check_api(port: u16, api_key: &str) -> Result<String, String> {
    // A 401 used to be retried once "because a config hot-reload rebuilds the
    // auth clients for a moment". The engine treats repeated bad credentials as
    // brute force: five 401s ban the loopback address for 30 minutes, so one
    // failed check cost two strikes and three clicks locked the user out even
    // with the correct key. The single attempt reports the real verdict.
    check_api_once(port, api_key)
        .await
        .map_err(|(code, text)| format!("{}: {}", code, text))
}

/// One check attempt. Failures carry the HTTP status (0 for transport errors).
async fn check_api_once(port: u16, api_key: &str) -> Result<String, (u16, String)> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| (0, e.to_string()))?;
    let models_response = client
        .get(format!("http://127.0.0.1:{}/v1/models", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await
        .map_err(|e| (0, e.to_string()))?;
    let models_status = models_response.status();
    let models_text = models_response
        .text()
        .await
        .map_err(|e| (0, e.to_string()))?;
    if !models_status.is_success() {
        return Err((
            models_status.as_u16(),
            models_text.chars().take(300).collect(),
        ));
    }
    let models: Value = serde_json::from_str(&models_text).map_err(|e| (0, e.to_string()))?;
    let model = models
        .get("data")
        .and_then(|d| d.as_array())
        .and_then(|arr| {
            arr.iter()
                .filter_map(|m| m.get("id").and_then(|v| v.as_str()))
                .find(|id| {
                    !id.starts_with("opencode/")
                        && !id.starts_with("openrouter/")
                        && !id.starts_with("deepinfra/")
                        && !id.starts_with("nvidia/")
                        && !id.starts_with("vercel/")
                        && !id.starts_with("zai/")
                })
                .or_else(|| {
                    arr.iter()
                        .filter_map(|m| m.get("id").and_then(|v| v.as_str()))
                        .next()
                })
        })
        .ok_or_else(|| {
            // Status 0 means "no answer" to the caller, but here the engine
            // answered 200 with an empty `data` array. Say so instead of
            // blaming the transport.
            (
                0,
                "the engine returned an empty model list from /v1/models".to_string(),
            )
        })?
        .to_string();

    let body = json!({
        "model": model,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 5
    });
    let response = client
        .post(format!("http://127.0.0.1:{}/v1/chat/completions", port))
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&body)
        .send()
        .await
        .map_err(|e| (0, e.to_string()))?;
    let status = response.status();
    let text = response.text().await.map_err(|e| (0, e.to_string()))?;
    if status.is_success() {
        Ok(text.chars().take(400).collect())
    } else {
        Err((status.as_u16(), text.chars().take(300).collect::<String>()))
    }
}

#[cfg(test)]
mod tests {
    use super::{
        adopt_matches, api_keys_yaml, api_keys_yaml_with_groups, api_keys_yaml_with_local,
        applied_reload_digest, auth_file_name, auth_payload, base_config, config_generation,
        config_needs_write, engine_strategy, format_affinity_ttl, image_matches_engine,
        image_starts_with, is_listening, is_listening_blocking, last_written_config,
        local_api_keys_yaml, lock_config_generation, parse_pid, parse_recent_call,
        parse_tasklist_image, parse_tasklist_pids, parse_usage_record, priority_for, quota_weight,
        reload_acknowledged, reload_digest, servable_local_models, sync_auth_files, tail_bytes,
        write_config,
        write_config_forced, write_config_if_changed, write_config_if_changed_forced,
        write_config_if_changed_locked, yaml_escape, RoutingTuning, PRIORITY_TIER_BACKUP,
        USER_AGENT,
    };
    use crate::settings::Settings;
    use crate::vault::Account;
    use serde_json::json;
    use std::collections::HashSet;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    /// Tests must not depend on what the developer has downloaded: the real
    /// `api_keys_yaml` reads the on-disk model registry, so a single installed
    /// GGUF would make every "no sources" assertion fail.
    fn api_keys_yaml_test(settings: &Settings) -> String {
        api_keys_yaml_with_local(settings, &[], 18318, "melon-local-test")
            .expect("routing groups are readable")
    }

    fn settings() -> Settings {
        Settings::default()
    }

    #[test]
    fn failed_auth_write_keeps_stale_files() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(".test-tmp")
            .join(format!("sync-fail-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let stale = dir.join("codex-stale.json");
        std::fs::write(&stale, "{}").expect("stale auth");
        // A directory where the auth file is expected makes the write fail on
        // every host, so the prune-after-write order can be observed.
        let blocked = dir.join("codex-blocked.json");
        std::fs::create_dir(&blocked).expect("blocked target");
        let desired = vec![(blocked.clone(), json!({"type": "codex"}), false)];
        assert!(
            sync_auth_files(&dir, desired).is_err(),
            "writing onto a directory must fail"
        );
        assert!(
            stale.exists(),
            "a failed auth write must not prune remaining auth files"
        );
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn successful_sync_writes_first_and_prunes_last() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(".test-tmp")
            .join(format!("sync-ok-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let stale = dir.join("codex-stale.json");
        std::fs::write(&stale, "{}").expect("stale auth");
        let wanted = dir.join("codex-live.json");
        let desired = vec![(wanted.clone(), json!({"type": "codex"}), false)];
        assert_eq!(sync_auth_files(&dir, desired).unwrap(), 1);
        assert!(
            !stale.exists(),
            "a successful sync prunes files absent from the snapshot"
        );
        assert_eq!(
            std::fs::read_to_string(&wanted).expect("written auth"),
            "{\n  \"type\": \"codex\"\n}"
        );
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn model_group_alias_replaces_the_provider_alias() {
        let mut s = settings();
        s.openrouter_enabled = true;
        s.openrouter_key = "or-key".into();
        s.openrouter_models = vec![crate::settings::ProviderModel {
            id: "openai/gpt-4o".into(),
            ..Default::default()
        }];
        let groups = vec![crate::routing_groups::Group {
            id: "g1".into(),
            alias: "smart".into(),
            note: String::new(),
            enabled: true,
            members: vec![crate::routing_groups::Member {
                source_id: "openrouter".into(),
                model_id: "openai/gpt-4o".into(),
            }],
        }];
        let yaml = api_keys_yaml_with_groups(&s, &[], 18317, "token", &groups);
        assert!(
            yaml.contains("        - name: \"openai/gpt-4o\"\n          alias: \"smart\"\n"),
            "{yaml}"
        );
        // A model outside every group keeps the namespaced alias.
        let none: &[crate::routing_groups::Group] = &[];
        let alone = api_keys_yaml_with_groups(&s, &[], 18317, "token", none);
        assert!(
            alone.contains("alias: \"openrouter/openai/gpt-4o\""),
            "{alone}"
        );
    }

    #[test]
    fn adopt_requires_the_identity_now_on_disk() {
        let probed = settings();
        let mut current = probed.clone();
        // Unchanged identity: the successful probe is still valid.
        assert!(adopt_matches(&probed, &current, false));

        current.api_key = "new-key".into();
        assert!(!adopt_matches(&probed, &current, false));
        assert!(adopt_matches(&probed, &current, true));

        // The health endpoint cannot prove a rotated management secret.
        current.management_secret = "new-secret".into();
        assert!(!adopt_matches(&probed, &current, true));
    }

    #[test]
    fn reload_acknowledgement_requires_the_v8_status_document() {
        assert!(reload_acknowledged(r#"{"status":"ok","config-version":8}"#));
        // The deprecated v0 route answered a different document; a 2xx of that
        // shape must not be read as an applied reload.
        assert!(!reload_acknowledged(r#"{"changed":["config"],"ok":true}"#));
        assert!(!reload_acknowledged(r#"{"status":"error"}"#));
        assert!(!reload_acknowledged(""));
        assert!(!reload_acknowledged("<html>gateway error</html>"));
    }

    #[test]
    fn reload_digest_is_read_only_from_a_v8_acknowledgement() {
        let digest = "a".repeat(64);
        assert_eq!(
            reload_digest(&format!(
                r#"{{"status":"ok","config-version":8,"reload-digest":"{digest}"}}"#
            )),
            Some(digest.clone())
        );
        // A v0 answer has no digest; the caller must not invent one.
        assert_eq!(reload_digest(r#"{"changed":["config"],"ok":true}"#), None);
        assert_eq!(reload_digest(r#"{"status":"ok","config-version":8}"#), None);
        assert_eq!(reload_digest(r#"{"reload-digest":7}"#), None);
        // An empty digest is not an identity and must not match anything.
        assert_eq!(reload_digest(r#"{"reload-digest":""}"#), None);
    }

    #[test]
    fn applied_digest_comes_from_the_status_document() {
        let digest = "b".repeat(64);
        assert_eq!(
            applied_reload_digest(&format!(
                r#"{{"saved-digest":"{digest}","applied-digest":"{digest}","pending":false}}"#
            )),
            Some(digest)
        );
        // A pending status without an applied digest is not a match, but an
        // empty digest is a readable answer and must not be mistaken for an
        // engine that lacks the contract.
        assert_eq!(applied_reload_digest(r#"{"pending":true}"#), None);
        assert_eq!(
            applied_reload_digest(r#"{"applied-digest":""}"#),
            Some(String::new())
        );
        assert_eq!(applied_reload_digest("<html>error</html>"), None);
    }

    #[test]
    fn base_config_carries_the_plaintext_management_secret() {
        let default_tuning = RoutingTuning {
            affinity: true,
            affinity_ttl: 7200,
            // The shipped default, so this test reads the config the app
            // actually writes: one retry turned a single upstream hiccup into
            // a 503 the client saw, two absorb it.
            retry: 2,
            cooldown: 60,
            strategy: "weighted-round-robin",
        };
        let yaml = base_config(
            18317,
            "melon-abc",
            "/tmp/auths",
            "melon-mgmt-1234",
            120,
            &default_tuning,
        );
        assert!(yaml.contains("secret-key: \"melon-mgmt-1234\""));
        // The old hard-coded bcrypt hash must be gone.
        assert!(!yaml.contains("$2a$"));
        assert!(yaml.contains("auth-dir: \"/tmp/auths\""));
        // Canonical v8 layout: `/v8/management/config.yaml` rejects every legacy
        // root, so the file we render must already use the names the engine
        // stores.
        assert!(
            yaml.contains("management:\n  allow-remote: false"),
            "{yaml}"
        );
        assert!(!yaml.contains("remote-management:"), "{yaml}");
        // Root-level, not nested under `routing:`: the engine reads these
        // from the config root and a nested copy is never applied.
        assert!(yaml.contains("\nrequest-retry: 2\n"), "{yaml}");
        assert!(yaml.contains("\nmax-retry-interval: 30\n"), "{yaml}");
        assert!(
            yaml.contains("\ntransient-error-cooldown-seconds: 60\n"),
            "{yaml}"
        );
        // Session affinity lives under `routing:` (it is a selection policy),
        // and only there: the retry knobs below it are root-level instead.
        assert!(yaml.contains("  session-affinity: true\n"), "{yaml}");
        assert!(
            yaml.contains("  session-affinity-rebind-on: \"any\"\n"),
            "{yaml}"
        );
        // The embedded engine carries MacOS/patches/0001, which reads this
        // root field and (after the same patch) accepts it in v8. Dropping it
        // from the file silently disabled the user's first-token watchdog.
        assert!(
            yaml.contains("stream-bootstrap-timeout-seconds: 120"),
            "{yaml}"
        );
    }

    #[test]
    fn routing_tuning_reaches_the_config_and_is_clamped() {
        let tuned = RoutingTuning {
            affinity: false,
            affinity_ttl: 1800,
            retry: 9,
            cooldown: 9000,
            strategy: "fill-first",
        };
        let yaml = base_config(18317, "melon-abc", "/tmp/auths", "sec", 0, &tuned);
        assert!(yaml.contains("  session-affinity: false\n"), "{yaml}");
        assert!(
            yaml.contains("  session-affinity-subagents: false\n"),
            "{yaml}"
        );
        assert!(yaml.contains("  session-affinity-ttl: \"30m\"\n"), "{yaml}");
        // Both knobs are clamped to the range the engine accepts.
        assert!(yaml.contains("\nrequest-retry: 5\n"), "{yaml}");
        assert!(
            yaml.contains("\ntransient-error-cooldown-seconds: 600\n"),
            "{yaml}"
        );
        // The gateway strategy is independent of the account order planner.
        assert!(yaml.contains("  strategy: \"fill-first\"\n"), "{yaml}");
    }

    #[test]
    fn gateway_strategy_falls_back_to_the_weighted_engine_value() {
        assert_eq!(engine_strategy("weighted"), "weighted-round-robin");
        assert_eq!(engine_strategy("roundRobin"), "round-robin");
        assert_eq!(engine_strategy("fillFirst"), "fill-first");
        // An empty or unknown value must never reach the engine as junk.
        assert_eq!(engine_strategy(""), "weighted-round-robin");
        assert_eq!(engine_strategy("auto"), "weighted-round-robin");
    }

    #[test]
    fn affinity_ttl_uses_the_engine_duration_spelling() {
        assert_eq!(format_affinity_ttl(7200), "2h");
        assert_eq!(format_affinity_ttl(1800), "30m");
        assert_eq!(format_affinity_ttl(90), "90s");
        // Below the minimum a binding churns on every request.
        assert_eq!(format_affinity_ttl(1), "30s");
    }

    #[test]
    fn yaml_escape_keeps_the_config_valid() {
        assert_eq!(yaml_escape("sk-\"quoted\\path"), "sk-\\\"quoted\\\\path");
        assert_eq!(yaml_escape("sk-line\nbreak"), "sk-linebreak");
    }

    #[test]
    fn config_write_is_skipped_for_an_unchanged_generation() {
        assert!(!config_needs_write("a", Some("a"), true));
        assert!(config_needs_write("b", Some("a"), true));
        assert!(config_needs_write("a", None, true));
        // A deleted config must be restored even when the generation matches.
        assert!(config_needs_write("a", Some("a"), false));
    }

    #[test]
    fn config_write_replaces_the_file_only_on_change() {
        let root =
            std::env::temp_dir().join(format!("melon-config-{}-{}", std::process::id(), line!()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("config.yaml");

        assert!(write_config_if_changed(&path, "config-version: 8\n").unwrap());
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "config-version: 8\n"
        );
        // Same generation: no write, no reload.
        assert!(!write_config_if_changed(&path, "config-version: 8\n").unwrap());
        assert!(write_config_if_changed(&path, "config-version: 9\n").unwrap());
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "config-version: 9\n"
        );

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_config_write_cannot_land_between_the_generation_check_and_the_acknowledgement() {
        let root = std::env::temp_dir().join(format!(
            "melon-config-generation-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("config.yaml");
        let mut written = std::collections::HashMap::new();
        assert!(
            write_config_if_changed_locked(&path, "config-version: 8\n", false, &mut written)
                .unwrap()
                .is_some()
        );

        // The publisher has checked this generation and is about to acknowledge
        // it. The writer below has a newer body and must not replace the file
        // until that acknowledgement is recorded.
        let guard = lock_config_generation();
        let generation = config_generation();
        let writer_done = Arc::new(AtomicBool::new(false));
        let writer = {
            let path = path.clone();
            let writer_done = Arc::clone(&writer_done);
            std::thread::spawn(move || {
                // Use the production critical section with a local write map,
                // so this test does not contend with unrelated tests over the
                // process-wide last-written cache.
                let mut written = std::collections::HashMap::new();
                write_config_if_changed_locked(&path, "config-version: 9\n", false, &mut written)
                    .unwrap()
                    .expect("the replacement must report its generation");
                writer_done.store(true, Ordering::SeqCst);
            })
        };

        // The ordinary write stages its temporary file before it takes the
        // generation lock. Waiting for that file proves the writer has reached
        // the replacement; it cannot finish while the publisher holds the lock.
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                !writer_done.load(Ordering::SeqCst),
                "the writer replaced config.yaml while the generation guard was held"
            );
            let staged = std::fs::read_dir(&root).unwrap().any(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".tmp")
            });
            if staged {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "the writer never staged a replacement"
            );
            std::thread::yield_now();
        }

        // The writer is parked between staging and the rename. Give an
        // uncovered writer enough time to finish: a rename and a counter bump
        // take microseconds, while a covered one cannot finish at all until the
        // guard is dropped. The bounded wait makes a missing guard fail here
        // instead of racing the assertions below.
        std::thread::sleep(Duration::from_millis(100));
        assert!(
            !writer_done.load(Ordering::SeqCst),
            "the writer replaced config.yaml while the generation guard was held"
        );

        // This is the acknowledgement the publication loop performs under the
        // same guard: the checked generation is still the newest one, and the
        // newer bytes are still only staged.
        assert!(guard.is_current(generation));
        assert_eq!(config_generation(), generation);
        drop(guard);

        writer.join().unwrap();
        assert!(writer_done.load(Ordering::SeqCst));
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "config-version: 9\n"
        );

        let guard = lock_config_generation();
        assert!(config_generation() > generation);
        assert!(
            !guard.is_current(generation),
            "a replaced generation must not be acknowledged"
        );
        drop(guard);

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn restore_replaces_older_engine_bytes_even_when_last_written_matches() {
        let root = std::env::temp_dir().join(format!(
            "melon-config-restore-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("config.yaml");
        let newest = "config-version: 8\napi-keys:\n  - name: local\n    models: [local/two]\n";
        let older = "config-version: 8\napi-keys:\n  - name: local\n    models: [local/one]\n";

        // The newest generation was written and recorded; a delayed engine
        // reload then persisted the older body it had received.
        assert!(write_config_if_changed(&path, newest).unwrap());
        std::fs::write(&path, older).unwrap();

        // The ordinary path trusts the in-memory generation and skips.
        assert!(!write_config_if_changed(&path, newest).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), older);

        // A restore must replace the mismatching disk bytes.
        assert!(write_config_if_changed_forced(&path, newest).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), newest);

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn forced_write_replaces_identical_config_for_local_add_and_remove() {
        let root = std::env::temp_dir().join(format!(
            "melon-config-forced-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("config.yaml");
        let with_model = "api-keys:\n  - name: \"melon-local-ai\"\n    models: [local/one]\n";
        let removed = "api-keys:\n  - name: \"melon-local-ai\"\n    models: []\n";

        // Add: the first write establishes the generation, then the engine
        // persists its own hashed copy and loses the reload. The repeated
        // identical forced write must still replace the file.
        assert!(write_config_if_changed(&path, with_model).unwrap());
        std::fs::write(&path, "engine: persisted\n").unwrap();
        assert!(write_config_if_changed_forced(&path, with_model).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), with_model);
        std::fs::write(&path, "engine: persisted\n").unwrap();
        assert!(write_config_if_changed_forced(&path, with_model).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), with_model);
        // The ordinary path stays idempotent in the same state.
        assert!(!write_config_if_changed(&path, with_model).unwrap());

        // Remove: a changed generation writes once, and a retry after another
        // lost reload must replace the identical removal YAML too.
        assert!(write_config_if_changed(&path, removed).unwrap());
        std::fs::write(&path, "engine: persisted\n").unwrap();
        assert!(write_config_if_changed_forced(&path, removed).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), removed);
        std::fs::write(&path, "engine: persisted\n").unwrap();
        assert!(write_config_if_changed_forced(&path, removed).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), removed);
        assert!(!write_config_if_changed(&path, removed).unwrap());

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_failed_replace_keeps_the_existing_destination() {
        let root = std::env::temp_dir().join(format!(
            "melon-config-preserve-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&root).unwrap();

        // Uncreatable temp file: any error before the replace must leave the
        // previous config untouched instead of truncating it. Directory
        // permissions are a Unix-only lever, so the whole scenario is gated;
        // the rename-failure case below runs everywhere.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let path = root.join("config.yaml");
            std::fs::write(&path, "old: config\n").unwrap();
            let mut permissions = std::fs::metadata(&root).unwrap().permissions();
            permissions.set_mode(0o555);
            std::fs::set_permissions(&root, permissions).unwrap();
            let error = write_config_if_changed_forced(&path, "new: config\n").unwrap_err();
            assert!(error.contains("config.yaml"), "{error}");
            assert_eq!(std::fs::read_to_string(&path).unwrap(), "old: config\n");
            assert!(
                last_written_config().lock().unwrap().get(&path).is_none(),
                "a failed write must not record the generation"
            );

            let mut restore = std::fs::metadata(&root).unwrap().permissions();
            restore.set_mode(0o755);
            std::fs::set_permissions(&root, restore).unwrap();
        }

        // Actual rename failure: a directory occupies the destination, so
        // `rename(tmp, path)` cannot land. Nothing inside it may be touched,
        // and the generation cache must stay empty.
        let occupied = root.join("occupied.yaml");
        std::fs::create_dir_all(&occupied).unwrap();
        std::fs::write(occupied.join("inner"), "keep me\n").unwrap();
        let error = write_config_if_changed_forced(&occupied, "new: config\n").unwrap_err();
        assert!(error.contains("occupied.yaml"), "{error}");
        assert!(occupied.is_dir());
        assert_eq!(
            std::fs::read_to_string(occupied.join("inner")).unwrap(),
            "keep me\n"
        );
        assert!(
            last_written_config()
                .lock()
                .unwrap()
                .get(&occupied)
                .is_none(),
            "a failed rename must not record the generation"
        );
        let leftover_tmp: Vec<_> = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name.starts_with(".occupied.yaml") && name.ends_with(".tmp"))
            .collect();
        assert!(
            leftover_tmp.is_empty(),
            "temporary files left: {leftover_tmp:?}"
        );

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_failed_forced_write_is_reported_and_not_marked_written() {
        assert!(write_config_forced(&settings()).is_err());

        let root = std::env::temp_dir().join(format!(
            "melon-config-forced-fail-{}-{}",
            std::process::id(),
            line!()
        ));
        let path = root.join("missing/config.yaml");
        let error = write_config_if_changed_forced(&path, "config-version: 8\n").unwrap_err();
        assert!(!error.is_empty());

        // The failure must not poison the generation: once the directory
        // exists, the ordinary write still reaches the file.
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        assert!(write_config_if_changed(&path, "config-version: 8\n").unwrap());
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "config-version: 8\n"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn write_config_refuses_an_empty_gateway_key() {
        // Settings::default() ships an empty key and secret; stripping the
        // config to an unusable state would break the running gateway.
        assert!(write_config(&settings()).is_err());
    }

    #[test]
    fn api_keys_yaml_is_empty_without_any_source() {
        assert_eq!(api_keys_yaml_test(&settings()), "");
    }

    #[test]
    fn api_keys_yaml_with_local_emits_melon_local_ai() {
        let s = settings();
        let model = crate::local_ai::LocalModel {
            id: "local/qwen2.5-coder-7b".to_string(),
            schema_version: None,
            display_name: "Qwen 2.5 Coder 7B".to_string(),
            provider: "Local AI".to_string(),
            source: "huggingface".to_string(),
            repo_id: Some("Qwen/Qwen2.5-Coder-7B-Instruct-GGUF".to_string()),
            revision: Some("main".to_string()),
            files: vec!["qwen2.5-coder-7b-instruct-q4_k_m.gguf".to_string()],
            file_size: 4680000000,
            quantization: "Q4_K_M".to_string(),
            format: "GGUF".to_string(),
            context_length: 32768,
            configured_context: 32768,
            backend: crate::local_ai::InferenceBackend::Cpu,
            gpu_offload: None,
            threads: None,
            runtime_status: crate::local_ai::ModelRuntimeStatus::Ready,
            capabilities: vec![crate::local_ai::ModelCapability::Text],
            installed_at: "2026-01-01T00:00:00Z".to_string(),
            updated_at: "2026-01-01T00:00:00Z".to_string(),
            last_used_at: None,
            license: None,
            checksum: None,
            architecture: None,
            user_settings: {
                crate::local_ai::LocalModelSettings {
                    context_length: 16384,
                    ..Default::default()
                }
            },
        };
        let yaml = super::api_keys_yaml_with_local(&s, &[model], 18318, "test-local-token-1234")
            .expect("routing groups are readable");
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        assert_eq!(yaml.matches("openai-compatibility:").count(), 1);
        assert!(yaml.contains("    - name: \"melon-local-ai\"\n"));
        assert!(yaml.contains("      base-url: \"http://127.0.0.1:18318/v1\"\n"));
        assert!(yaml.contains("api-key: \"test-local-token-1234\""));
        // The local engine must bypass the egress proxy.
        assert!(yaml.contains("proxy-url: \"direct\""));
        assert!(yaml.contains("name: \"local/qwen2.5-coder-7b\""));
        assert!(yaml.contains("alias: \"local/qwen2.5-coder-7b\""));
        assert!(yaml.contains("display-name: \"Qwen 2.5 Coder 7B\""));
        assert!(yaml.contains("max-context-length: 16384"));
    }

    /// REVIEW gap: the published config must follow the *live* registry status,
    /// not just the presence of a row. `Ready` is what the runtime writes after
    /// `/health` answered; `Installed` means no engine is serving it, so it
    /// must disappear from `/v1/models`.
    ///
    /// `api_keys_yaml` also reads the internal token, which lives outside the
    /// thread-local test registry. Point `LOCALAPPDATA` at the temp root for
    /// the duration and serialize that process-global override.
    #[test]
    fn api_keys_yaml_advertises_only_runtime_ready_models() {
        use crate::local_ai::local_models::{self, with_test_root, LocalModelStore};
        use crate::local_ai::ModelRuntimeStatus;

        static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _env = ENV_LOCK.lock().unwrap_or_else(|error| error.into_inner());
        let root =
            std::env::temp_dir().join(format!("melon-gateway-status-{}", uuid::Uuid::new_v4()));
        let previous = std::env::var_os("LOCALAPPDATA");
        std::env::set_var("LOCALAPPDATA", &root);

        with_test_root(&root, || {
            LocalModelStore::save_registry(&[local_models::test_model(
                "local/ready",
                ModelRuntimeStatus::Ready,
            )])
            .unwrap();
            assert_eq!(servable_local_models().len(), 1);
            let yaml = api_keys_yaml(&settings());
            assert!(yaml.contains("name: \"melon-local-ai\""), "{yaml}");
            assert!(yaml.contains("local/ready"), "{yaml}");
            // The publication promises exactly the aliases this YAML declares;
            // a second snapshot is what made the poll wait for a model the
            // file no longer listed.
            let (rendered, aliases) =
                local_api_keys_yaml(&settings()).expect("routing groups are readable");
            assert_eq!(aliases, vec!["local/ready".to_string()]);
            assert_eq!(rendered, yaml);
            for alias in &aliases {
                assert!(rendered.contains(alias), "{alias} missing from {rendered}");
            }

            LocalModelStore::save_registry(&[local_models::test_model(
                "local/installed",
                ModelRuntimeStatus::Installed,
            )])
            .unwrap();
            assert!(servable_local_models().is_empty());
            let yaml = api_keys_yaml(&settings());
            assert!(!yaml.contains("melon-local-ai"), "{yaml}");
            assert!(!yaml.contains("local/installed"), "{yaml}");
        });

        match previous {
            Some(value) => std::env::set_var("LOCALAPPDATA", value),
            None => std::env::remove_var("LOCALAPPDATA"),
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Writes the shared native fixture consumed by
    /// `scripts/test_local_ai_gateway.py`. Ignored by default: it writes a file
    /// outside the test temp dir, so CI keeps it opt-in:
    ///
    /// ```text
    /// MELON_LOCAL_AI_FIXTURE=/tmp/melon-local-ai-windows.yaml \
    ///   cargo test write_engine_api_keys_fixture -- --ignored
    /// ```
    /// One Ready local model with placeholder values, so the generated config
    /// and the tracked fixture differ only in what the parent script replaces.
    fn engine_fixture_model() -> crate::local_ai::LocalModel {
        crate::local_ai::LocalModel {
            id: "local/__MODEL_ID__".to_string(),
            schema_version: None,
            display_name: String::new(),
            provider: "Local AI".to_string(),
            source: "huggingface".to_string(),
            repo_id: None,
            revision: None,
            files: Vec::new(),
            file_size: 0,
            quantization: String::new(),
            format: "GGUF".to_string(),
            context_length: 0,
            configured_context: 0,
            backend: crate::local_ai::InferenceBackend::Cpu,
            gpu_offload: None,
            threads: None,
            runtime_status: crate::local_ai::ModelRuntimeStatus::Ready,
            capabilities: vec![crate::local_ai::ModelCapability::Text],
            installed_at: "2026-01-01T00:00:00Z".to_string(),
            updated_at: "2026-01-01T00:00:00Z".to_string(),
            last_used_at: None,
            license: None,
            checksum: None,
            architecture: None,
            user_settings: crate::local_ai::LocalModelSettings::default(),
        }
    }

    /// The tracked fixture must be byte-for-byte what the app generates, so the
    /// real-engine E2E tests a native config instead of a hand-written schema.
    #[test]
    fn generated_gateway_config_matches_the_tracked_engine_fixture() {
        let yaml = super::api_keys_yaml_with_local(
            &settings(),
            &[engine_fixture_model()],
            59999,
            "__LOCAL_TOKEN__",
        )
        .expect("routing groups are readable");
        let tracked = include_str!("../../tools/fixtures/local-ai-gateway.yaml");
        assert_eq!(yaml.trim_end(), tracked.trim_end());
    }

    /// Regenerates the fixture when the generator changes on purpose:
    /// `MELON_LOCAL_AI_FIXTURE=… cargo test write_engine_api_keys_fixture -- --ignored`.
    #[test]
    #[ignore = "writes the shared gateway fixture for the real-engine E2E"]
    fn write_engine_api_keys_fixture() {
        let yaml = super::api_keys_yaml_with_local(
            &settings(),
            &[engine_fixture_model()],
            59999,
            "__LOCAL_TOKEN__",
        )
        .expect("routing groups are readable");
        let path = std::env::var_os("MELON_LOCAL_AI_FIXTURE")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::env::temp_dir().join("melon-local-ai-windows.yaml"));
        std::fs::write(&path, &yaml).expect("write fixture");
        eprintln!("wrote gateway fixture: {}", path.display());
    }

    #[test]
    fn api_keys_yaml_uses_one_root_for_opencode_openrouter_and_claude() {
        let mut s = settings();
        s.opencode_key = "oc-key".to_string();
        s.openrouter_key = "or-key".to_string();
        s.claude_enabled = true;
        s.claude_api_key = "sk-ant-key".to_string();
        let yaml = api_keys_yaml_test(&s);
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        assert!(yaml.contains("  openai-compatibility:\n"));
        assert!(yaml.contains("    - name: \"opencode-go\"\n"));
        assert!(yaml.contains("    - name: \"openrouter\"\n"));
        assert!(yaml.contains("  claude:\n"));
        assert!(yaml.contains("    - name: \"claude\"\n"));
        assert!(yaml.contains("      base-url: \"https://api.anthropic.com\"\n"));
        assert!(yaml.contains("        - api-key: \"sk-ant-key\"\n"));
        // Claude models keep a slash-less alias so the gateway lists raw ids.
        assert!(yaml.contains(
            "        - name: \"claude-opus-5-5\"\n          alias: \"claude-opus-5-5\"\n"
        ));
    }

    #[test]
    fn api_keys_yaml_openrouter_only_still_emits_the_root() {
        let mut s = settings();
        s.openrouter_key = "or-key".to_string();
        let yaml = api_keys_yaml_test(&s);
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        assert!(yaml.contains("  openai-compatibility:\n"));
        assert!(yaml.contains("    - name: \"openrouter\"\n"));
        assert!(!yaml.contains("  claude:\n"));
    }

    #[test]
    fn api_keys_yaml_carries_deepinfra_and_vercel_models() {
        let mut s = settings();
        s.deepinfra_key = "di-key".to_string();
        s.deepinfra_models = vec![crate::settings::ProviderModel {
            id: "deepseek-ai/DeepSeek-V4".to_string(),
            display: "DeepSeek V4".to_string(),
            context_window: Some(131_072),
            ..Default::default()
        }];
        s.vercel_key = "vc-key".to_string();
        s.vercel_models = vec![crate::settings::ProviderModel {
            id: "anthropic/claude-sonnet-4.6".to_string(),
            display: "Claude Sonnet 4.6".to_string(),
            ..Default::default()
        }];
        let yaml = api_keys_yaml_test(&s);
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        assert!(yaml.contains("    - name: \"deepinfra\"\n"));
        assert!(yaml.contains("      base-url: \"https://api.deepinfra.com/v1/openai\"\n"));
        assert!(yaml.contains("        - name: \"deepseek-ai/DeepSeek-V4\"\n          alias: \"deepinfra/deepseek-ai/DeepSeek-V4\"\n"));
        assert!(yaml.contains("          display-name: \"DeepSeek V4\"\n"));
        assert!(yaml.contains("          max-context-length: 131072\n"));
        assert!(yaml.contains("    - name: \"vercel\"\n"));
        assert!(yaml.contains("      base-url: \"https://ai-gateway.vercel.sh/v1\"\n"));
        assert!(yaml.contains("alias: \"vercel/anthropic/claude-sonnet-4.6\"\n"));
    }

    #[test]
    fn api_keys_yaml_carries_nvidia_models() {
        let mut s = settings();
        s.nvidia_key = "test-key".to_string();
        s.nvidia_enabled = true;
        s.nvidia_models = vec![crate::settings::ProviderModel {
            id: "vendor/model".to_string(),
            ..Default::default()
        }];
        let yaml = api_keys_yaml_test(&s);
        assert!(yaml.contains("base-url: \"https://integrate.api.nvidia.com/v1\""));
        assert!(yaml.contains("alias: \"nvidia/vendor/model\""));
        s.nvidia_enabled = false;
        assert!(!api_keys_yaml_test(&s).contains("name: \"nvidia\""));
    }

    #[test]
    fn api_keys_yaml_carries_zai_coding_models() {
        let mut s = settings();
        s.zai_key = "id.secret".to_string();
        s.zai_models = vec![
            crate::settings::ProviderModel {
                id: "glm-5.3".to_string(),
                display: "GLM-5.3".to_string(),
                context_window: Some(1_000_000),
                supports_images: Some(false),
                ..Default::default()
            },
            crate::settings::ProviderModel {
                id: "glm-5.3-flash".to_string(),
                display: "GLM-5.3 Flash".to_string(),
                context_window: Some(1_000_000),
                supports_images: Some(true),
                ..Default::default()
            },
        ];
        let yaml = api_keys_yaml_test(&s);
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        assert!(yaml.contains("  openai-compatibility:\n"));
        assert!(yaml.contains("    - name: \"zai\"\n"));
        assert!(yaml.contains("      base-url: \"https://api.z.ai/api/coding/paas/v4\"\n"));
        assert!(yaml.contains("        - api-key: \"id.secret\"\n"));
        assert!(yaml.contains("        - name: \"glm-5.3\"\n          alias: \"zai/glm-5.3\"\n"));
        assert!(yaml.contains("          display-name: \"GLM-5.3 Flash\"\n"));
        assert!(yaml.contains("          max-context-length: 1000000\n"));
    }

    #[test]
    fn api_keys_yaml_splits_commandcode_by_endpoint() {
        let mut s = settings();
        s.commandcode_key = "cmd-key".to_string();
        s.commandcode_models = vec![
            crate::settings::ProviderModel {
                id: "claude-sonnet-5-5".to_string(),
                display: "Claude Sonnet 5.5".to_string(),
                context_window: Some(1_000_000),
                anthropic_only: Some(true),
                ..Default::default()
            },
            crate::settings::ProviderModel {
                id: "gpt-6-astra".to_string(),
                display: "GPT-6 Astra".to_string(),
                anthropic_only: Some(false),
                ..Default::default()
            },
        ];
        let yaml = api_keys_yaml_test(&s);
        assert_eq!(yaml.matches("api-keys:").count(), 1);
        // OpenAI-compatible models ride one upstream, Claude models the other.
        assert!(yaml.contains("    - name: \"commandcode\"\n"));
        assert!(yaml.contains("      base-url: \"https://api.commandcode.ai/provider/v1\"\n"));
        assert!(yaml.contains(
            "        - name: \"gpt-6-astra\"\n          alias: \"commandcode/gpt-6-astra\"\n"
        ));
        let split = yaml.find("  claude:\n").expect("claude section");
        let (openai_part, claude_part) = yaml.split_at(split);
        // Claude ids stay out of the OpenAI-compatible upstream.
        assert!(!openai_part.contains("claude-sonnet-5-5"));
        assert!(claude_part.contains("    - name: \"commandcode-anthropic\"\n"));
        assert!(claude_part.contains("        - name: \"claude-sonnet-5-5\"\n          alias: \"commandcode/claude-sonnet-5-5\"\n"));
        assert!(!claude_part.contains("gpt-6-astra"));
    }

    #[test]
    fn group_alias_reaches_the_anthropic_commandcode_block() {
        use crate::routing_groups::{Group, Member};
        let mut s = settings();
        s.commandcode_key = "cmd-key".to_string();
        s.commandcode_models = vec![crate::settings::ProviderModel {
            id: "claude-sonnet-5-5".to_string(),
            display: "Claude Sonnet 5.5".to_string(),
            anthropic_only: Some(true),
            ..Default::default()
        }];
        let groups = vec![Group {
            id: "g1".to_string(),
            alias: "smart".to_string(),
            note: String::new(),
            enabled: true,
            members: vec![Member {
                source_id: "commandcode".to_string(),
                model_id: "claude-sonnet-5-5".to_string(),
            }],
        }];
        let yaml = api_keys_yaml_with_groups(&s, &[], 18318, "token", &groups);
        let split = yaml.find("  claude:\n").expect("claude section");
        let (_, claude_part) = yaml.split_at(split);
        assert!(
            claude_part
                .contains("        - name: \"claude-sonnet-5-5\"\n          alias: \"smart\"\n"),
            "{claude_part}"
        );
        assert!(
            claude_part.contains(
                "        - name: \"claude-sonnet-5-5\"\n          alias: \"commandcode/claude-sonnet-5-5\"\n"
            ),
            "{claude_part}"
        );
    }

    #[test]
    fn api_keys_yaml_uses_the_fetched_opencode_catalogue() {
        let mut s = settings();
        s.opencode_key = "oc-key".to_string();
        s.opencode_models = vec![crate::settings::ProviderModel {
            id: "claude-fable-5".to_string(),
            display: "Claude Fable 5".to_string(),
            prompt_per_token: Some(0.00001),
            ..Default::default()
        }];
        let yaml = api_keys_yaml_test(&s);
        assert!(yaml.contains("    - name: \"opencode-go\"\n"));
        assert!(yaml.contains(
            "        - name: \"claude-fable-5\"\n          alias: \"opencode/claude-fable-5\"\n"
        ));
        // The built-in fallback list stays out once a catalogue was fetched.
        assert!(!yaml.contains("alias: \"opencode/kimi-k3\""));
    }

    #[test]
    fn api_keys_yaml_skips_providers_without_cached_models() {
        let mut s = settings();
        s.deepinfra_key = "di-key".to_string();
        s.vercel_key = "vc-key".to_string();
        assert_eq!(api_keys_yaml_test(&s), "");
        s.deepinfra_enabled = false;
        s.deepinfra_models = vec![crate::settings::ProviderModel {
            id: "chat".to_string(),
            display: "Chat".to_string(),
            ..Default::default()
        }];
        assert_eq!(api_keys_yaml_test(&s), "");
    }

    #[test]
    fn api_keys_yaml_claude_requires_the_key_and_the_switch() {
        let mut s = settings();
        s.claude_api_key = "sk-ant-key".to_string();
        // Enabled is still false: nothing is emitted.
        assert_eq!(api_keys_yaml_test(&s), "");
        s.claude_enabled = true;
        assert!(api_keys_yaml_test(&s).contains("  claude:\n"));
        // A whitespace-only key never reaches the config.
        s.claude_api_key = "   ".to_string();
        assert_eq!(api_keys_yaml_test(&s), "");
    }

    fn custom_provider(
        id: &str,
        protocol: &str,
        base_url: &str,
        models: Vec<crate::settings::CustomProviderModel>,
    ) -> crate::settings::CustomProvider {
        crate::settings::CustomProvider {
            id: id.to_string(),
            name: id.to_string(),
            base_url: base_url.to_string(),
            protocol: protocol.to_string(),
            api_key: format!("sk-{id}"),
            enabled: true,
            models,
            priority: None,
            headers: std::collections::BTreeMap::new(),
        }
    }

    fn custom_model(id: &str, enabled: bool) -> crate::settings::CustomProviderModel {
        crate::settings::CustomProviderModel {
            id: id.to_string(),
            display: id.to_string(),
            context_window: Some(64_000),
            enabled,
            alias: String::new(),
        }
    }

    /// A custom provider's tier and headers reach the config. Without them a
    /// provider behind Cloudflare answers `error code: 1010` to the engine's
    /// default `Go-http-client`, and a fast provider cannot be preferred
    /// without taking it out of the failover chain.
    #[test]
    fn api_keys_yaml_carries_provider_priority_and_headers() {
        let mut s = settings();
        let mut provider = custom_provider(
            "acme",
            "openai-chat",
            "https://relay.example/v1",
            vec![custom_model("gpt-5", true)],
        );
        provider.priority = Some(7);
        provider
            .headers
            .insert("User-Agent".to_string(), "AcmeClient/2.0".to_string());
        s.custom_providers = vec![provider];

        let yaml = api_keys_yaml_test(&s);
        assert!(yaml.contains("      priority: 7\n"), "{yaml}");
        assert!(yaml.contains("      headers:\n"), "{yaml}");
        assert!(
            yaml.contains("        User-Agent: \"AcmeClient/2.0\"\n"),
            "{yaml}"
        );
        // A provider that names no headers still gets the baseline ones, so
        // it is not refused by a Cloudflare front.
        let mut bare = custom_provider(
            "bare",
            "openai-chat",
            "https://bare.example/v1",
            vec![custom_model("gpt-5", true)],
        );
        bare.priority = Some(0);
        s.custom_providers = vec![bare];
        let yaml = api_keys_yaml_test(&s);
        assert!(
            !yaml.contains("      priority: 0\n"),
            "zero is omitted: {yaml}"
        );
        assert!(
            yaml.contains("        User-Agent: \"MelonTools/1.4 (Windows)\"\n"),
            "{yaml}"
        );
    }

    #[test]
    fn api_keys_yaml_routes_custom_providers_into_protocol_sections() {
        let mut s = settings();
        s.custom_providers = vec![
            custom_provider(
                "acme",
                "openai-chat",
                "https://relay.example/v1",
                vec![custom_model("gpt-5", true), custom_model("hidden", false)],
            ),
            custom_provider(
                "acme-responses",
                "openai-responses",
                "https://responses.example/v1",
                vec![custom_model("gpt-5-pro", true)],
            ),
            custom_provider(
                "acme-claude",
                "anthropic",
                "https://messages.example/v1",
                vec![custom_model("claude-sonnet", true)],
            ),
            custom_provider(
                "acme-gemini",
                "gemini",
                "https://gemini.example/v1beta",
                vec![custom_model("gemini-pro", true)],
            ),
        ];

        let yaml = api_keys_yaml_test(&s);

        assert_eq!(yaml.matches("api-keys:").count(), 1, "{yaml}");
        assert!(yaml.contains("  openai-compatibility:\n"), "{yaml}");
        assert!(yaml.contains("  codex:\n"), "{yaml}");
        assert!(yaml.contains("  claude:\n"), "{yaml}");
        assert!(yaml.contains("  gemini:\n"), "{yaml}");
        assert!(
            yaml.contains("    - name: \"acme\"\n      base-url: \"https://relay.example/v1\""),
            "{yaml}"
        );
        assert!(yaml.contains("alias: \"acme/gpt-5\""), "{yaml}");
        assert!(!yaml.contains("hidden"), "{yaml}");
        assert!(
            yaml.contains("base-url: \"https://messages.example\""),
            "{yaml}"
        );
        assert!(!yaml.contains("messages.example/v1\""), "{yaml}");
        assert!(
            yaml.contains("base-url: \"https://gemini.example\""),
            "{yaml}"
        );
        assert!(!yaml.contains("gemini.example/v1beta\""), "{yaml}");
        assert!(yaml.contains("alias: \"acme-gemini/gemini-pro\""), "{yaml}");
    }

    #[test]
    fn api_keys_yaml_skips_disabled_invalid_and_empty_custom_providers() {
        let mut s = settings();
        let mut disabled = custom_provider(
            "acme",
            "openai-chat",
            "https://relay.example/v1",
            vec![custom_model("gpt-5", true)],
        );
        disabled.enabled = false;
        let invalid_id = custom_provider(
            "Acme",
            "openai-chat",
            "https://relay.example/v1",
            vec![custom_model("gpt-5", true)],
        );
        let no_models = custom_provider(
            "empty",
            "openai-chat",
            "https://relay.example/v1",
            vec![custom_model("gpt-5", false)],
        );
        let no_key = {
            let mut provider = custom_provider(
                "keyless",
                "openai-chat",
                "https://relay.example/v1",
                vec![custom_model("gpt-5", true)],
            );
            provider.api_key = "   ".to_string();
            provider
        };
        s.custom_providers = vec![disabled, invalid_id, no_models, no_key];
        assert_eq!(api_keys_yaml_test(&s), "");
    }

    fn group(source: &str, model: &str) -> crate::routing_groups::Group {
        crate::routing_groups::Group {
            id: "g1".into(),
            alias: "smart".into(),
            note: String::new(),
            enabled: true,
            members: vec![crate::routing_groups::Member {
                source_id: source.into(),
                model_id: model.into(),
            }],
        }
    }

    /// A disabled custom model that a group lists still answers to the group
    /// alias. The direct `provider/model` alias is exactly what disabling it
    /// removes, so it must not come back through the ordinary fallback.
    #[test]
    fn disabled_custom_model_keeps_only_its_group_alias() {
        let mut s = settings();
        s.custom_providers = vec![custom_provider(
            "acme",
            "openai-chat",
            "https://relay.example/v1",
            vec![custom_model("gpt-5", true), custom_model("hidden", false)],
        )];
        let groups = vec![group("acme", "hidden")];
        let yaml = api_keys_yaml_with_groups(&s, &[], 18318, "token", &groups);

        assert!(yaml.contains("alias: \"acme/gpt-5\""), "{yaml}");
        assert!(yaml.contains("alias: \"smart\""), "{yaml}");
        assert!(
            !yaml.contains("alias: \"acme/hidden\""),
            "a disabled model must not regain its direct alias: {yaml}"
        );
        let entry = yaml
            .split("- name: \"hidden\"")
            .nth(1)
            .expect("disabled model entry")
            .split("- name:")
            .next()
            .unwrap();
        assert!(entry.contains("alias: \"smart\""), "{yaml}");
    }

    /// The provider check used to skip a provider whose models were all
    /// disabled, which hid the only group alias that still routed to it.
    #[test]
    fn custom_provider_with_only_a_grouped_disabled_model_is_emitted() {
        let mut s = settings();
        s.custom_providers = vec![custom_provider(
            "acme",
            "openai-chat",
            "https://relay.example/v1",
            vec![custom_model("hidden", false)],
        )];
        assert_eq!(
            api_keys_yaml_with_groups(&s, &[], 18318, "token", &[]),
            "",
            "without a group the provider has nothing to serve"
        );
        let yaml =
            api_keys_yaml_with_groups(&s, &[], 18318, "token", &[group("acme", "hidden")]);
        assert!(yaml.contains("    - name: \"acme\""), "{yaml}");
        assert!(yaml.contains("- name: \"hidden\""), "{yaml}");
        assert!(yaml.contains("alias: \"smart\""), "{yaml}");
    }

    #[test]
    fn missing_auth_directory_is_an_error_instead_of_an_empty_success() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(".test-tmp")
            .join(format!("sync-missing-{}", uuid::Uuid::new_v4()));
        let error = sync_auth_files(&dir, Vec::new()).expect_err("missing directory");
        assert!(error.contains("cannot read auth directory"), "{error}");
    }


    /// An auth file the app owns but cannot parse is not a blank slate:
    /// overwriting it would lose a legacy pause flag and silently re-enable a
    /// route the user disabled. The sync must refuse to proceed.
    #[test]
    fn corrupt_existing_auth_file_is_a_hard_failure() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(".test-tmp")
            .join(format!("sync-corrupt-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let file = dir.join("codex-stale.json");
        std::fs::write(&file, "not json").expect("corrupt auth");
        let desired = vec![(file.clone(), json!({"type": "codex"}), true)];
        let error = sync_auth_files(&dir, desired).expect_err("corrupt auth file");
        assert!(error.contains("corrupt auth file"), "{error}");
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "not json",
            "a corrupt file must not be overwritten"
        );
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }

    /// Deterministic removal failure without chmod: the stale entry is a
    /// directory, and unlink on a directory fails on every host. The sync
    /// must report the failure instead of a successful count.
    #[test]
    fn unreposable_stale_entry_fails_the_prune() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join(".test-tmp")
            .join(format!("sync-stale-dir-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let stale = dir.join("codex-stale.json");
        std::fs::create_dir(&stale).expect("stale dir entry");
        let result = sync_auth_files(&dir, Vec::new());
        assert!(result.is_err(), "a stale entry that cannot be removed must fail");
        let error = result.unwrap_err();
        assert!(error.contains("cannot remove stale auth file"), "{error}");
        assert!(stale.exists(), "the stale entry is still there");
        std::fs::remove_dir_all(&dir).expect("cleanup");
    }

    #[test]
    fn pool_tiers_map_to_gateway_priority() {
        // Regular accounts share the top tier, backups the one below: equal
        // values are what let the engine rotate inside a tier.
        assert_eq!(priority_for(0), 2);
        assert_eq!(priority_for(PRIORITY_TIER_BACKUP), 1);
        assert!(priority_for(0) > priority_for(PRIORITY_TIER_BACKUP));
    }

    fn pool(slugs: &[&str]) -> HashSet<String> {
        slugs.iter().map(|slug| slug.to_string()).collect()
    }

    fn pool_account(selection: Option<Vec<String>>) -> Account {
        Account {
            id: "pool-account".to_string(),
            tokens: crate::vault::Tokens {
                access_token: Some("access-token".to_string()),
                ..Default::default()
            },
            selected_models: selection,
            ..Default::default()
        }
    }

    #[test]
    fn excluded_account_keeps_full_credentials_but_cannot_route() {
        let mut account = pool_account(None);
        account.pool_enabled = Some(false);
        let payload = auth_payload(&account, 0, &pool(&["gpt-6-sol"]));
        assert_eq!(payload["disabled"], true);
        assert_eq!(payload["access_token"], "access-token");
        assert_eq!(payload["type"], "codex");
        account.pool_enabled = Some(true);
        assert!(auth_payload(&account, 1, &pool(&[]))
            .get("disabled")
            .is_none());
    }

    /// The share must track the quota left, not sit at a constant: that is the
    /// whole point of writing the weight from the cached reading.
    #[test]
    fn quota_weight_scales_with_remaining_quota() {
        fn weight(hourly: Option<f64>, weekly: Option<f64>) -> u64 {
            let mut account = pool_account(None);
            account.quota = Some(crate::vault::Quota {
                hourly_remaining_percent: hourly,
                weekly_remaining_percent: weekly,
                ..Default::default()
            });
            quota_weight(&account)
        }
        // A fresh account has the widest share; the scale tops out at 10.
        assert_eq!(weight(Some(100.0), Some(100.0)), 10);
        assert_eq!(weight(Some(95.0), Some(95.0)), 9);
        assert_eq!(weight(Some(12.0), Some(12.0)), 1);
        // The tighter of the two windows decides, so a drained weekly window
        // cannot be masked by a healthy 5-hour one.
        assert_eq!(weight(Some(90.0), Some(12.0)), 1);
        // The last percent stays routable; excluding an account is the job of
        // `disabled`, and a zero weight would drop it out of the picker.
        assert_eq!(weight(Some(0.0), Some(0.0)), 1);
        // An account with no reading yet must not be starved.
        let unknown = pool_account(None);
        assert_eq!(quota_weight(&unknown), 10);
    }

    #[test]
    fn auth_payload_lists_excluded_models_for_a_restricted_selection() {
        let all = pool(&["gpt-6-luna", "gpt-6-sol", "gpt-6-astra", "gpt-5.5"]);
        let account = pool_account(Some(vec![
            "gpt-6-sol".to_string(),
            "gpt-6-astra".to_string(),
            // Outside the pool: it cannot appear in the picker, so it never
            // becomes an exclusion.
            "unknown-model".to_string(),
        ]));

        let payload = auth_payload(&account, 2, &all);

        assert_eq!(payload["excluded_models"], json!(["gpt-5.5", "gpt-6-luna"]));
        assert_eq!(payload["priority"], 2);
        assert_eq!(payload["access_token"], "access-token");
        assert_eq!(payload["type"], "codex");
        assert!(payload.get("disabled").is_none());
    }

    #[test]
    fn auth_payload_omits_excluded_models_for_a_full_selection() {
        let all = pool(&["gpt-6-luna", "gpt-6-sol"]);

        // Legacy vault: `None` means the whole pool.
        let legacy = auth_payload(&pool_account(None), 1, &all);
        assert!(legacy.get("excluded_models").is_none());

        // An explicit list covering every visible model excludes nothing.
        let full = auth_payload(
            &pool_account(Some(vec![
                "gpt-6-luna".to_string(),
                "gpt-6-sol".to_string(),
            ])),
            1,
            &all,
        );
        assert!(full.get("excluded_models").is_none());
    }

    #[test]
    fn auth_file_name_without_email_is_stable_across_order_indexes() {
        let account = Account {
            id: "abc-123-def".to_string(),
            ..Default::default()
        };
        let first = auth_file_name(&account, 0);
        let second = auth_file_name(&account, 7);
        assert_eq!(first, second);
        assert!(first.contains("account-abc123def"));
    }

    #[test]
    fn user_agent_derives_from_the_crate_version() {
        assert_eq!(
            USER_AGENT,
            format!("MelonTools/{}", env!("CARGO_PKG_VERSION"))
        );
        let mut s = settings();
        s.opencode_key = "oc-key".to_string();
        assert!(api_keys_yaml_test(&s).contains(&format!("user-agent: \"{}\"", USER_AGENT)));
    }

    #[test]
    fn pid_file_parsing_accepts_only_positive_ids() {
        assert_eq!(parse_pid("1234"), Some(1234));
        assert_eq!(parse_pid(" 1234\n"), Some(1234));
        assert_eq!(parse_pid("0"), None);
        assert_eq!(parse_pid(""), None);
        assert_eq!(parse_pid("12 34"), None);
        assert_eq!(parse_pid("pid=1234"), None);
    }

    #[test]
    fn tasklist_csv_parsing() {
        let output = "\"cliproxyapi.exe\",\"4321\",\"Console\",\"1\",\"12,345 K\"\r\n";
        assert_eq!(
            parse_tasklist_image(output).as_deref(),
            Some("cliproxyapi.exe")
        );
        assert_eq!(parse_tasklist_pids(output), vec![4321]);
        assert_eq!(
            parse_tasklist_image("INFO: No tasks are running which match the specified criteria."),
            None
        );
        assert!(parse_tasklist_pids("INFO: No tasks are running").is_empty());
        let two = "\"ChatGPT.exe\",\"10\",\"Console\",\"1\",\"1 K\"\r\n\"ChatGPT.exe\",\"11\",\"Console\",\"1\",\"1 K\"\r\n";
        assert_eq!(parse_tasklist_pids(two), vec![10, 11]);
    }

    #[test]
    fn pid_identity_matches_only_the_engine() {
        assert!(image_matches_engine("cliproxyapi.exe"));
        assert!(image_matches_engine(
            "CLIProxyAPI-x86_64-pc-windows-msvc.exe"
        ));
        assert!(image_matches_engine("C:\\Tools\\cliproxyapi.exe"));
        assert!(!image_matches_engine("chatgpt.exe"));
        assert!(!image_matches_engine("notcliproxyapi.exe"));
        assert!(image_starts_with("ChatGPT.exe", "chatgpt"));
        assert!(!image_starts_with("ChatGPT-helper.exe", "chatgpt.exe"));
    }

    #[test]
    fn recent_call_parser_matches_the_engine_log_format() {
        let call = parse_recent_call(
            "[2026-10-21 12:00:00] [a1b2c3d4] [info ] 200 |       1.2s |       127.0.0.1 | POST    \"/v1/responses\"",
        )
        .expect("call");
        assert_eq!(call["status"], "200");
        assert_eq!(call["duration"], "1.2s");
        assert_eq!(call["method"], "POST");
        assert_eq!(call["path"], "/v1/responses");
        assert!(parse_recent_call("not a call").is_none());
    }

    #[test]
    fn usage_record_parser_matches_the_engine_log_format() {
        let line = "[2026-11-10 18:00:00] [12345678] [info ] [telemetry_logger.go:75] [usage] timestamp=2026-11-10T18:00:00Z model=claude-3-7-sonnet provider=anthravity auth=test-account-1 input=150 output=320 mode=stream status=200";
        let record = parse_usage_record(line).expect("usage record");
        assert_eq!(record["timestamp"], "2026-11-10T18:00:00Z");
        assert_eq!(record["model"], "claude-3-7-sonnet");
        assert_eq!(record["provider"], "anthravity");
        assert_eq!(record["auth"], "test-account-1");
        assert_eq!(record["input"], 150);
        assert_eq!(record["output"], 320);
        assert_eq!(record["mode"], "stream");
        assert_eq!(record["status"], 200);
        assert!(parse_usage_record("not a usage line").is_none());
    }

    #[test]
    fn bounded_tail_drops_the_partial_first_line() {
        let data = b"partial line\nfull line one\nfull line two\n";
        assert_eq!(
            tail_bytes(data, true),
            b"full line one\nfull line two\n".as_slice()
        );
        assert_eq!(tail_bytes(data, false), data.as_slice());
        // A single over-long line is kept (bounded by the read cap).
        assert_eq!(tail_bytes(b"one huge line", true), b"one huge line");
    }

    #[tokio::test]
    async fn only_an_open_port_counts_as_a_listening_gateway() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(
            is_listening_blocking(port),
            "the synchronous supervisor probe must see a bound port"
        );
        assert!(
            is_listening(port).await,
            "a bound loopback port must count as available"
        );
        drop(listener);
        assert!(
            !is_listening_blocking(port),
            "a closed port must not schedule a publication"
        );
        assert!(
            !is_listening(port).await,
            "the async probe must agree with the synchronous one"
        );
    }

    #[test]
    fn shared_routing_priority_fixture() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../../../shared/fixtures/routing.json")).unwrap();
        let ids = fixture["orderedIds"].as_array().unwrap();
        let expected = fixture["priorities"].as_object().unwrap();
        let backups = fixture["backupIds"].as_array().unwrap();
        for id in ids.iter() {
            let id = id.as_str().unwrap();
            let tier = if backups.iter().any(|b| b.as_str() == Some(id)) {
                PRIORITY_TIER_BACKUP
            } else {
                0
            };
            assert_eq!(
                priority_for(tier),
                expected[id].as_u64().unwrap() as usize,
                "{id}"
            );
        }
    }

    #[test]
    fn openrouter_provider_settings_inherit_per_field() {
        let mut settings = settings();
        settings.openrouter_key = "test-key".into();
        settings.openrouter_models = vec![crate::settings::ProviderModel {
            id: "example/model".into(),
            ..Default::default()
        }];
        settings.openrouter_config.order = vec!["global-order".into()];
        settings.openrouter_config.only = vec!["global-only".into()];
        settings.openrouter_config.ignore = vec!["global-ignore".into()];
        settings.openrouter_config.allow_fallbacks = false;
        let override_config = serde_json::from_str(r#"{"order":["specific"]}"#).unwrap();
        settings
            .openrouter_config
            .model_providers
            .insert("example/model".into(), override_config);
        let yaml = api_keys_yaml_test(&settings);
        assert!(yaml.contains("\\\"order\\\":[\\\"specific\\\"]"));
        assert!(yaml.contains("\\\"only\\\":[\\\"global-only\\\"]"));
        assert!(yaml.contains("\\\"ignore\\\":[\\\"global-ignore\\\"]"));
        assert!(yaml.contains("\\\"allow_fallbacks\\\":false"));
    }

    #[test]
    fn openrouter_payload_structure() {
        let mut settings = settings();
        settings.openrouter_key = "test-key".into();
        settings.claude_enabled = true;
        settings.claude_api_key = "test-claude".into();
        settings.openrouter_config.default_strategy = "price".to_string();
        settings.openrouter_models = vec![crate::settings::ProviderModel {
            id: "openai/gpt-4o".to_string(),
            display: "GPT-4o".to_string(),
            ..Default::default()
        }];
        settings
            .openrouter_config
            .models
            .insert("openai/gpt-4o".to_string(), "nitro".to_string());

        let yaml = api_keys_yaml_test(&settings);

        assert!(
            yaml.contains("\npayload:\n  default-raw:\n"),
            "Payload root missing or nested incorrectly"
        );
        assert!(
            yaml.contains("    - models:\n        - name: \"openrouter/openai/gpt-4o\"\n"),
            "Model name pattern incorrect"
        );
        assert!(
            yaml.contains("\\\"sort\\\":\\\"throughput\\\""),
            "Sort strategy incorrect"
        );
        assert!(yaml.contains("        - name: \"openai/gpt-4o:nitro\"\n          alias: \"openrouter/openai/gpt-4o\"\n"), "Model mapping missing or incorrect");
        assert!(
            yaml.find("\n  claude:\n").unwrap() < yaml.find("\npayload:\n").unwrap(),
            "Claude block should appear before payload"
        );
    }
}
