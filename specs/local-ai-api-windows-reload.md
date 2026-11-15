# Local AI API publication — Windows management reload

## SPEC

- Phase: REVIEW → REPAIR7 applied → awaiting re-review (code-path evidence
  only; no Windows host was available in this session).
- Task slug: `local-ai-api-windows-reload`.
- Parent record: `specs/local-ai-api-windows.md` (frozen; R1–R5 remain in force).
- Baseline revision: `b8556ff` (working tree dirty by design: no commits allowed).
- Date: 2026-11-06.

### Objective

A model loaded by Local AI on Windows is running (`РАБОТАЕТ: QWEN3.5 2B BF16`) but
absent from the gateway catalogue (`0 доступно моделей`), with the diagnostic
"The gateway did not publish local/unsloth-… after repeated config rewrites".
Publication must not depend on the engine's filesystem watcher, and the
diagnostic must not claim a cause the app never observed.

### Current / desired behavior

- Current: `publish_attempt` writes `config.yaml`, `PUT`s the deprecated
  `/v0/management/config.yaml`, then polls `/v1/models`. The v0 handler only
  validates and rewrites the file; the catalogue changes when fsnotify fires.
  A missed notification leaves the process serving the old catalogue for its
  whole life, and every retry repeats the same steps.
- Desired: each round writes the file **and** hands the same bytes to
  `PUT /v8/management/config.yaml`, whose handler calls the reload hook
  directly. The expected alias set comes from the very YAML that was written.

### Scope

`Windows/app/src-tauri/src/gateway.rs` (canonical v8 `base_config`, explicit
reload, publication struct), `Windows/app/src-tauri/src/local_ai/commands.rs`
(outcome-driven write+reload hook, failure message). No UI, version, or
installed-app change. No engine source change.

### Requirements

- **R1 Watcher-independent publication.** Every publication round applies the
  just-written `config.yaml` through `/v8/management/config.yaml`, which runs
  `reloadConfigFromWatcher()` itself; a missed fsnotify event cannot leave the
  model unlisted.
- **R2 Honest diagnostics.** A 4xx/5xx from the management API reaches the user
  with the engine's message; the message must not claim a rejection when the
  engine is simply not running, and must not assert an unobserved cause.
- **R3 Truthful bookkeeping.** A revision whose reload was refused or not
  acknowledged is never recorded as published, even transiently.
- **R4 Single credential attempt per round.** The reload uses the management
  secret that was just written, once per round: five wrong attempts from one IP
  ban the client for 30 minutes.
- **R5 No restart, no broken requests.** The config is applied in place; the
  gateway is never restarted for publication.
- **R6 No false claims in code.** Comments and guards must match the engine's
  actual behavior (catalogue validation is asynchronous and never rejects
  `config.yaml`).
- **R7 Single publication snapshot.** The alias set a publication waits for is
  read from the YAML rendered for that same round; a separate snapshot taken
  before the write is forbidden.
- **R8 Applied completion contract.** A 2xx from the management PUT means
  accepted, not applied. The publication may treat the reload as applied only
  when the engine reports the digest of the exact saved bytes as applied; a
  missing endpoint, a legacy hook, a plugin host, or an error must leave the
  revision pending. A generation comparison is not a substitute.
- **R9 Serialized config writes.** Every local writer (`save_settings`,
  `gateway_sync`, the catalogue debounce, shutdown, publication) renders and
  replaces `config.yaml` under one lock, reading the current settings inside
  it. A publication that detects a newer local generation before or after its
  reload must not poll or mark the revision synced; the next round publishes
  the newer state.

### Check plan (required)

- `cargo test --bin melontools` — full suite, zero failures.
- `cargo xwin check --target x86_64-pc-windows-msvc --tests` — the Windows lane
  compiles, including the new tests.
- Live engine probe (macOS host, same v8 engine): `/v8/management/config.yaml`
  publishes `local/…` without a watcher event; a legacy body returns
  `400 invalid_config`; an invalid body returns `400 invalid_yaml`.
- Optional: `node app/tools/local-connections-check.js` (UI contract unchanged).

### Done criteria

R1–R9 verified by the checks above; no uncovered correctness or regression
finding remains in this record. The current Windows payload contains the
`/v8/management/reload-status` and digest symbols, but no Windows host was
available to exercise them, and the release artifacts were produced before the
final tree. Rebuild and regenerate provenance before shipping (see
"Residual").

## EVIDENCE

### Engine contract (read from `MacOS/_sources/CLIProxyAPI`, v8.0.44)

- `internal/api/handlers/management/config_basic.go:129` `PutConfigYAML`
  (`/v0/management/config.yaml`) validates the body with
  `LoadConfigOptional(optional=false)`, writes the file and assigns `h.cfg`. It
  **never calls the reload hook**; only the fsnotify watcher rebuilds clients.
- `internal/api/handlers/management/config_v8.go:27` `ConfigV8`
  (`PUT /v8/management/config.yaml`) saves the tree and then calls
  `h.reloadConfigAfterManagementSaveAsync(...)` (`config_v8.go`, tail of the
  PUT branch).
- `internal/api/handlers/management/handler.go:246` `reloadConfigAfterManagementSave`
  → `hook(ctx, cfg)`; the hook is installed in
  `sdk/cliproxy/builder.go:301` as `service.reloadConfigFromWatcher`, which calls
  `watcher.ReloadConfigIfChanged()` (`sdk/cliproxy/service_config.go:286`) — an
  explicit, synchronous, fsnotify-independent reload.
- `/v8` requires the canonical v8 layout: a legacy root is rejected with
  `400 {"error":"invalid_config"}`, e.g.
  `legacy field remote-management.allow-remote is not accepted by v8; use management.allow-remote`
  and `unknown v8 configuration section stream-bootstrap-timeout-seconds`.
- `internal/config/config_v8.go` `expandV8Groups` converts
  `api-keys.openai-compatibility[].keys[]` into `api-key-entries`; the catalogue
  `id` is the entry `alias`, `owned_by` is the provider `name`.
- `internal/registry/catalog_sources.go:75-84` starts the catalogue reader in a
  goroutine; `:121-125` logs "model catalog rejected; keeping last valid
  catalog". A malformed `models.json` therefore never rejects `config.yaml`.

### Live probe (2026-11-06, engine at 127.0.0.1:18999)

- Deprecated endpoint: `PUT /v0/management/config.yaml` → `200
  {"changed":["config"],"ok":true}`; no `config successfully reloaded` line and
  no client rebuild; the catalogue changes only after the watcher fires.
- Legacy Windows-shaped body on `/v8/management/config.yaml` → `400
  {"error":"invalid_config","message":"legacy field remote-management.allow-remote
  is not accepted by v8; use management.allow-remote"}`.
- Canonical v8 body on `/v8/management/config.yaml` → `200
  {"config-version":8,"status":"ok"}`; engine log shows `config successfully
  reloaded, triggering client reload` and `1 clients (… +1 OpenAI-compat)`;
  `GET /v1/models` lists `local/test-model` with a fresh `created` value.
- Adding a stray `stream-bootstrap-timeout-seconds: 120` root to an engine
  built from the patch set **without** the v8 allowlist hunk failed with
  `unknown v8 configuration section …`. The field is not dead: the embedded
  engine is built from `MacOS/patches/0001-stream-bootstrap-qos.patch`, which
  adds `Config.StreamBootstrapTimeoutSeconds` (`config.go:73`) and calls
  `coreauth.SetStreamBootstrapTimeout(cfg.StreamBootstrapTimeoutSeconds)`.
  REPAIR3 adds the same root to `v8AllowedRoots()` inside patch 0001, and a
  rebuild of the patch set now accepts it end to end:
  `PUT /v8/management/config.yaml` with
  `stream-bootstrap-timeout-seconds: 120` answered
  `200 {"config-version":8,"status":"ok"}`, the engine logged
  `[qos] watchdog configured timeout_s=120`, and
  `GET /v8/management/config.yaml` still returned the field while
  `openai-compatibility` was applied in the same reload.
- Appending an invalid line made the engine keep the old catalogue and a
  follow-up request answered `400 {"error":"invalid_yaml",…}`. The app must
  surface that text (R2).
- The exact envelope the app now emits (`config-version: 8` + `management:` +
  `routing.retry`/`routing.cooldown` + `api-keys.openai-compatibility` with two
  local models) returned `200 {"config-version":8,"status":"ok"}`, produced the
  reload log line and listed both aliases in `/v1/models`. So the canonical
  layout change and the local provider block are accepted together, not only
  in isolation.
- `reload_acknowledged` is unit-tested against the three bodies that matter:
  the v8 document, the deprecated v0 document and a non-JSON proxy error page.

### Async acceptance (R3)

`PUT /v8/management/config.yaml` calls
`h.reloadConfigAfterManagementSaveAsync(...)` (`config_v8.go`), and that helper
starts the work in a goroutine (`handler.go`, `go func()` around the
`reloadConfigAfterManagementSave` call). The HTTP 200 is therefore written
before `Service.reloadConfigFromWatcher` has run; it means "queued", not
"applied". Reading the catalogue immediately after the 2xx can still show the
previous generation, and a reload that later fails cannot retroactively change
the already-sent 200. R3 consequently requires `mark_synced` only after
`/v1/models` matches the alias set of the bytes in the same round.

### No completion signal exists (R3, second pass)

A catalogue match is convergence, not proof of application. Both available
config reads were checked and neither exposes the reload result:

- `GET /v0/management/config.yaml` (`config_basic.go`, `GetConfigYAML`) reads
  `h.configFilePath` from disk — it proves only the write this app performed.
- `GET /v8/management/config.yaml` (`config_v8.go`) also reads and normalises
  the file, so it has the same limitation.
- `GET /v0/management/config` (`GetConfig`) returns `new(*h.cfg)`, but
  `ConfigV8` assigns `h.cfg = next` synchronously before writing the 200, so the
  value is the requested generation rather than an applied one.

The engine exposes `appliedReloadGeneration` only inside the handler; no
management route reports it, and `/v1/models` carries aliases but not the port
or token behind them. When a transition changes only the port or the internal
token while the alias set stays identical, the previous generation already
matches the expected catalogue, so equality can hold before the reload
goroutine runs. The app therefore:

- keeps `mark_synced` as a bounded convergence signal (otherwise the 5 s
  supervisor rewrites the same file forever), and
- does not describe it as proof anywhere in code, messages or this record.
- retries a failed publication with a per-revision backoff of 15 s doubling to
  5 min (`PublicationGate::retry_in`/`record_failure`); a new revision retries
  immediately and a converged one clears the delay, so a permanently broken
  engine is still retried without a rewrite on every tick.

### Single snapshot (R7)

- Before REPAIR2, `sync_gateway_after_transition` built `expected` from
  `servable_local_models()` and the YAML was rendered later from a second call
  in `gateway::write_config_with`. A stop/start between the two made the poll
  wait for an alias the file no longer declared. `reconcile_router_state()` runs
  every 5 s and every lifecycle transition bumps the revision, so the window is
  reachable; the reported incident is **not** claimed to be this race.
- After REPAIR2 `write_config_with` returns `ConfigPublication { yaml,
  local_models }` from one render, and `publish_attempt` takes `expected` from
  each round's outcome.

### Empty expected set (F6)

Before REPAIR3, `published == expected` was trivially true when both sets were
empty, so a publication performed while no model was `Ready` marked the
revision synced and produced no `publicationError` even when the reload had
been refused. After REPAIR3 the empty set is an explicit expectation derived
from the file ("the file declares no local aliases"): the poll must observe an
empty catalogue before `mark_synced`, and a refused reload is reported and
leaves the revision pending. The symptom class matches the screenshot, but the
incident log was not available, so this record does not claim the incident was
this code path.

### Working tree

- `git diff --stat` before REPAIR1: `gateway.rs +47`, `catalog.rs +64`,
  `commands.rs +308/−48` (the latter two included pre-existing uncommitted work
  from the parent lane). After REPAIR1 `catalog.rs` is byte-identical to the
  baseline.
- After REPAIR2: `gateway.rs` emits canonical v8, `reload_config` targets
  `/v8`, both callers of the config write use the returned publication.
- After REPAIR3: the QoS root is back in `base_config`; patch 0001 also adds it
  to `v8AllowedRoots()`; `AppState.settings` moved to `Arc<Mutex<Settings>>`;
  `reload_config` returns `ReloadFailure::{Auth,Refused}`; the publication gate
  carries an auth block keyed by port+secret; `mark_synced` waits for the
  catalogue in the same round.
- At REPAIR3 the rebuilt Windows artifacts contained the new path (`strings`
  finds `v8/management/config.yaml` and `engine acknowledged the rewritten
  config.yaml`). At that point the payload was 74,485,248 bytes SHA-256
  `8585884d…` and the packed blob was 24,252,436 bytes SHA-256 `f10482ab…`.
  These values are historical; the current tree has the newer blob described
  below. `Windows/dist/cliproxyapi-x86_64-pc-windows-msvc.exe` still carries
  the pre-rebuild digest `7aba21df…`; it is a stale local artifact, not an
  input to the app bundle.
- After REPAIR7 (F16 restore + F17 adopt): `cargo test --bin melontools` 470
  passed, 0 failed, 1 ignored (139.24 s); `cargo xwin check --target
  x86_64-pc-windows-msvc --tests` finished clean. The Go tree and patch 0004
  were not touched by REPAIR7; their last runs remain `go test
  ./internal/api/handlers/management/ -count=1` green and `git apply --check`
  of the 570-line patch on `1f917e77` after 0001–0003.
- REPAIR6 result retained for comparison: 468 passed, 0 failed, 1 ignored
  (80.90 s), same clean Windows cross-check.
- Bundled engine artifacts are **intermediate**, not final release inputs. The
  current Windows payload is 74,491,392 bytes SHA-256 `adaabfe5…` inside
  `cliproxyapi.exe.z` (24,252,187 bytes, SHA-256 `5603d841…`);
  `strings` finds `/v8/management/reload-status`, `reload-digest` and
  `applied-digest`, so the blob is not the older `8585884d…` payload that
  predated the contract. That proves symbol presence only: no Windows run
  exercised the endpoint, and the provenance file still describes the same
  source commit/tag without recording this repair. `Windows/dist/cliproxyapi-x86_64-pc-windows-msvc.exe`
  is 74,485,248 bytes SHA-256 `7aba21df…` — stale relative to the resource
  blob. The macOS `MacOS/build/cliproxyapi` is 145,435,554 bytes SHA-256
  `513eebf1…`. Rebuild `Windows/app/resources/cliproxyapi.exe.z`,
  `engine-provenance.json`, the macOS engine and the dist executable from the
  final tree before shipping; this record does not claim that rebuild. The
  engine changes are carried by
  `MacOS/patches/0004-v8-reload-status.patch` (570 lines, result hook + digest
  + tests), verified to apply on `1f917e77` after patches 0001–0003 and to
  contain no `/v0/management` edit.

## REVIEW

Self-review of the working tree plus the independent review the parent agent
supplied before REPAIR3 (it reopened F5 and produced F8/F9) and before REPAIR5
(it produced F11–F13). This record does not claim a further external review of
the REPAIR5 diff.

| ID | Requirement | Verdict | Evidence |
|----|-------------|---------|----------|
| R1 | Watcher-independent publication | PASS after F4 | `gateway.rs` `reload_config` `PUT /v8/management/config.yaml`; engine hook proven in source and live probe |
| R2 | Honest diagnostics | PASS after F3, F6, F8 | "did not confirm" for any non-2xx or missing acknowledgement plus engine text; empty-catalogue branch states only observed facts |
| R3 | Truthful bookkeeping | PASS after F2, F6 | `mark_synced` only when `/v1/models` matches the round's alias set, including the empty set; a refused reload stays pending |
| R4 | Single credential attempt | PASS after F8 | one `PUT` per publication, same secret; a 401/403 blocks the port+secret pair until it changes, so the engine's five-failure ban is not reached |
| R5 | No restart | PASS | management reload only; `gateway::start` untouched |
| R6 | No false claims in code | PASS after F1, F5, F6 | guard removed from `catalog.rs`; v0 comment corrected; message no longer claims a dropped provider; the QoS root is emitted because the engine reads it |
| R7 | Single publication snapshot | PASS after F7, F9, F14 | `ConfigPublication` from one render; `publish_attempt` reads `expected` per round; settings are re-read from the shared `Arc` inside every round; a settings save merges the UI payload under the settings lock instead of replaying a pre-probe snapshot |
| R8 | Applied completion contract | PASS after F11 | `PUT` returns `reload-digest`; the client requires `applied-digest` equality; legacy/plugin paths never publish an applied digest |
| R9 | Serialized config writes | PASS after F12, F14, F15, F17 | one write transaction for all writers; `CONFIG_GENERATION` detects a save that lands before or during the reload and the round is not polled; the superseded restore is forced because the engine may already have persisted the older body; the start path reloads settings after its catalogue await and refuses to adopt a process whose key/secret no longer matches the file; a stopped engine still gets the newest file |

### Findings

- **F11 (R8) — CLOSED by REPAIR5.** `commands.rs` treated the v8 `200` as
  proof that the reload ran, then compared `applied-generation >= requested`
  against a counter the engine never exposed, so the comparison could not
  distinguish "this document applied" from "some later document applied".
  The management PUT also answered before the reload goroutine ran, and the
  builder hook discarded `reloadConfigFromWatcher()`'s success. Remedy applied:
  `PUT /v8/management/config.yaml` re-reads the bytes it saved, hashes them
  (`config.ComputeSourceHash`) and returns `reload-digest`; the new
  `GET /v8/management/reload-status` returns `saved-digest`,
  `applied-digest` and `pending`. A new `configReloadResultHook` carries the
  real `applyConfigUpdateWithAuthSynthesis(..., false) bool`; only `true`
  publishes the applied digest and advances `applied-generation`. The legacy
  void hook and the plugin host keep delivery ordering but leave the status
  pending. `>=` is gone. Closing verification:
  `config_v8_reload_status_test.go` covers async completion, concurrent saves,
  identical digests, failed apply, an unapplied save, and digest/document
  agreement; `go test ./internal/api/handlers/management/ -count=1` is green.
- **F12 (R9) — CLOSED by REPAIR5.** Each writer took its own `Settings`
  snapshot before the write lock, and the catalogue debounce captured a clone
  350 ms before writing, so a save or stop in between was overwritten by older
  values. The publication read settings once and reused that snapshot for
  every retry. A `last_written` mutex around the file replacement alone does
  not cover the gap up to the asynchronous PUT: another writer can replace the
  file after the publication writes it, and the PUT then applies the older
  document. Remedy applied: `write_config_from(load, force)` holds the lock
  across `load()` (current settings), render, compare and atomic replace; all
  four `main.rs` writers and the publication call it with a loader, and the
  debounce loads after its sleep. `ConfigPublication` carries the exact
  `port`/`management_secret`/`generation` it wrote, so the reload targets
  those bytes. `CONFIG_GENERATION` is bumped under the same lock; the
  publication compares it before the PUT (skips an obsolete document) and
  after it (restores the newest file, marks the round `superseded`, and never
  polls or calls `mark_synced`). Three superseded rounds end in an honest
  pending error. Closing verification: 26 publication tests including
  `a_superseded_snapshot_is_neither_polled_nor_marked_synced`; full Rust suite
  466 passed; `cargo xwin check --tests` green. This is detection and repair,
  not a lock held across the `await`: the record says so instead of claiming
  serialization through the reload.
- **F14 (R7/R9) — CLOSED by REPAIR6.** `settings_set` read the whole
  `Settings` object, awaited the health probe, then saved the payload it had
  received. Any `mutate_settings` command that ran during the probe (routing
  strategy, priority order, Codex path, update-check timestamp, provider
  model lists) was overwritten by the older values in that payload. The same
  path wrote `config.yaml` only when the probe said the engine was running,
  so a stopped or just-starting engine kept the old port/key on disk. Remedy
  applied: `settings::merge_user_payload(payload, before, current)` merges
  under the settings lock after the probe and takes `current` for every field
  whose payload value still equals `before`; app-managed secrets and reset
  markers fall back to `current`; provider models are carried from `current`.
  The config is now written on every save, independent of the health result
  (`write_config_current` still renders the live state under the write lock).
  Closing verification: `a_stale_payload_keeps_fields_changed_while_the_probe_was_running`,
  `a_real_payload_edit_wins_over_the_live_value`; full Rust suite 468 passed.
- **F15 (R9) — CLOSED by REPAIR6.** `gateway::start` took a `&Settings`
  snapshot, awaited `catalog::refresh_for_start()` (bounded but multi-second),
  then wrote that pre-await snapshot and used it for `sync_accounts` and for
  the Codex catalogue/registration done by `start_gateway`. A save landing
  during the refresh was overwritten on disk and the Codex pointer used the
  old port/key. Remedy applied: `start` takes a loader (`Fn() -> Settings`),
  reloads the live settings after the refresh and again after the write, and
  probes health with a freshly loaded port/key. All four call sites
  (`main.rs:290/1716/1755/2393`) pass `|| state.settings()`;
  `start_gateway` reloads the settings after `start` before touching Codex.
  Closing verification: full Rust suite and `cargo xwin check --tests`; the
  await/reload ordering is a code-path property (no Windows host).
- **F16 (R8/R4) — CLOSED by REPAIR6.** Three residual error-path defects:
  an `Err` from the reload after the engine had already saved the body did
  not restore a newer local save; the restore ran but the failure still
  recorded an auth block for the superseded fingerprint; and a superseded
  round could spend the five-failure budget on a credential that no longer
  matched the file. Remedy applied: the `Err` branch compares
  `CONFIG_GENERATION`, restores the newest state with `write_config_current`
  and returns `superseded`; `auth_refused` is suppressed when the round was
  superseded, so the next round probes its own fingerprint instead of
  inheriting a stale ban. A superseded round is never polled or marked synced,
  and three superseded rounds end in the existing honest pending error.
  REPAIR7 closes the remaining restore hole: the restore used the non-forced
  `write_config_current`, whose skip predicate compares only against the
  in-memory last-written YAML. When the engine had already persisted the older
  body, that map still named the newest generation, so the restore returned
  success without touching the mismatching disk bytes. Both restore paths now
  call `write_config_current_forced` and log a failed replacement.
  Closing verification: `restore_replaces_older_engine_bytes_even_when_last_written_matches`
  reproduces exactly that state (newest recorded in memory, older bytes on
  disk, ordinary write skips, forced write replaces); 26 publication tests
  including the auth-cooldown and released-claim cases; full Rust suite 470
  passed.
- **F17 (R9) — CLOSED by REPAIR7.** The adopted-engine branch probed health
  with the settings snapshot read before the rewrite, then wrote the live
  config and returned `adopted` without checking that the process still
  matched it. A save landing during the probe or the write could change the
  port, API key or management secret; `sync_accounts` and Codex then used the
  new credentials against a process still serving the old ones (the Windows
  watcher is not a reliable reload signal). Remedy applied:
  `adopt_matches` accepts the process only when the identity now on disk is
  unchanged, or when a fresh probe with the new port/key answers; a rotated
  management secret cannot be proven through public health and always forces
  the restart path. Closing verification:
  `adopt_requires_the_identity_now_on_disk` (unchanged, changed key with a
  negative/positive probe, changed secret); full Rust suite 470 passed. No
  Windows host was available, so the actual restart is a code-path property.
- **F13 (R4) — CLOSED by REPAIR5.** The gate recorded the auth block after
  `release`, so the next 5 s supervisor tick could claim the slot in the gap
  and immediately repeat the refused request; the cooldown was not tied to the
  engine's 30-minute ban, and every attempt after expiry could spend another
  of the five failures. Remedy applied: block/backoff are recorded before
  `release`; `AUTH_COOLDOWN` is 31 minutes; `AuthBlock` carries
  `fingerprint`, `until` and `probe_taken`, so exactly one probe is allowed
  after expiry, a refused probe starts a new cooldown, a non-auth failure
  releases the probe, and a success clears the block. Closing verification:
  `an_auth_block_outlives_the_engine_ban_and_allows_one_probe`,
  `a_refused_probe_restarts_the_cooldown`,
  `a_released_claim_already_carries_the_failure_state`.
- **F1 (R6) — CLOSED by REPAIR1.** `catalog_is_loadable` / `config_block_at` rest on a false premise.
  The engine reads `models.catalog` in a background goroutine and keeps the last
  valid catalogue on error, so an unloadable `models.json` cannot freeze
  `/v1/models`. The guard adds a JSON parse on every config write for no
  behavioral gain and its comment misstates the engine.
  Remedy applied: `catalog.rs` reverted to `is_file()` only, guard helper and
  its test deleted.
  Closing verification: `git diff -- catalog.rs` is empty; full suite green.
- **F2 (R3) — CLOSED by REPAIR3 (was REPAIR1).** `mark_synced` was called as
  soon as the write hook returned, before the engine accepted the file, so a
  refused reload was recorded as a published revision. REPAIR1 moved it to an
  acknowledged reload, which was still wrong: `PUT /v8/management/config.yaml`
  writes the 200 before the reload goroutine runs, so "acknowledged" means
  "queued". Remedy applied: the revision is marked synced only inside the poll
  loop, when `/v1/models` equals the alias set of the bytes written in the same
  round. That equality is convergence, not application: with unchanged aliases
  the previous generation already matches, and no management read exposes the
  reload result (see "No completion signal exists"). The match is still the
  bound that stops the supervisor from rewriting the file forever. Closing
  verification:
  `a_published_snapshot_marks_the_revision_synced` asserts one catalogue read
  and a cleared pending revision; `a_lost_reload_stays_dirty_and_is_reported`
  asserts the pending revision and the message when the catalogue never
  matches.
- **F3 (R2) — CLOSED by REPAIR1.** `publication_failure_message` said "The
  engine rejected the rewritten config.yaml" for any non-2xx, including a
  missing management endpoint and a network timeout; only the engine text says
  whether the YAML was refused. Remedy applied: neutral "did not confirm" plus
  the engine text, because a 2xx without the v8 status document stored the file
  without claiming the reload ran. Closing verification:
  `publication_failure_names_the_reload_rejection`.
- **F4 (R1) — CLOSED by REPAIR2.** The reload used the deprecated
  `/v0/management/config.yaml`, which does not call the reload hook. It rewrites
  the file and `h.cfg`, but the client list and `/v1/models` still change only
  when the fsnotify watcher fires — exactly the dependency R1 forbids, and the
  live probe confirmed no reload log line on v0. Remedy applied:
  `reload_config` targets `/v8/management/config.yaml`, sends the exact bytes,
  and requires the `{"status":"ok","config-version":8}` acknowledgement; a 2xx
  without it is a failure, a refused reload ends the attempt without polling a
  catalogue the engine never acknowledged, and the supervisor's next pass
  rewrites the file (one management attempt per publication, so a wrong secret
  cannot spend the engine's five-attempt ban in a single call). Closing
  verification:
  live probe on the same engine (`200 status ok`, reload log, catalogue
  rebuilt) with the app-shaped envelope; `reload_acknowledgement_requires_the_v8_status_document`
  and `a_refused_reload_is_attempted_once_and_never_polled`; `cargo xwin check`
  compiles the new path. The 200-is-async part is documented under EVIDENCE and
  covered by F2's catalogue-confirmation tests.
- **F5 (R6) — REOPENED and CLOSED by REPAIR3.** REPAIR2 removed the root
  `stream-bootstrap-timeout-seconds` because `/v8` rejected it and this record
  claimed no engine struct read it. That claim was wrong: the embedded engine
  is built from `MacOS/patches/0001-stream-bootstrap-qos.patch`, which adds
  `Config.StreamBootstrapTimeoutSeconds` and configures the first-token
  watchdog from it, so REPAIR2 silently disabled a documented user setting that
  macOS emits too. Remedy applied: the field is emitted again, and the same
  portable patch adds `allowed["stream-bootstrap-timeout-seconds"] = true` to
  `v8AllowedRoots()` so v8 accepts the app's own layout. `base_config` keeps the
  canonical `management:`/`routing:` layout. Closing verification:
  `base_config_carries_the_plaintext_management_secret` now requires
  `stream-bootstrap-timeout-seconds: 120`; `git apply --check` of patches
  0001-0003 on a clean checkout of `1f917e77…`; live `PUT /v8/management/config.yaml`
  with the field answered 200 and logged `[qos] watchdog configured timeout_s=120`.
- **F6 (R2/R6) — CLOSED by REPAIR2, extended by REPAIR3.** The empty-catalogue
  branch asserted "the provider entry itself was dropped", which the app cannot
  observe: it only sees `HTTP 200` and an empty local set. REPAIR2 removed the
  claim. REPAIR3 additionally removed the "nothing to publish + unhealthy
  gateway => quiet success" shortcut: an empty `expected` now means "the file
  declares no local aliases", so the poll must observe an empty catalogue before
  marking synced, and a refused reload with an empty set is reported and stays
  pending. Closing verification:
  `a_refused_reload_with_nothing_to_publish_is_reported_and_pending` and
  `a_round_with_nothing_to_publish_is_quiet`.
- **F7 (R7) — CLOSED by REPAIR2.** Two snapshots of one truth: `expected` from
  `servable_local_models()` in `commands.rs` and the YAML from a second call in
  `gateway.rs`. Remedy applied: `ConfigPublication` returns both from one
  render, and `publish_attempt` takes `expected` from the round's outcome;
  `a_later_round_publishes_the_set_its_own_file_declares` covers the change
  between rounds. Closing verification:
  `api_keys_yaml_advertises_only_runtime_ready_models` asserts the returned
  aliases equal the aliases present in the rendered YAML.
- **F8 (R4) — CLOSED by REPAIR3.** The retry loop could repeat a management
  request with a secret the engine already rejects. `AuthenticateManagementKey`
  counts every failure per client IP and bans the loopback address for 30
  minutes after five (`handler.go`, `maxFailures = 5`,
  `banDuration = 30 * time.Minute`), so a 5 s supervisor pass reaches the ban in
  about 25 s; a success resets the counter and a pause does not. Remedy applied:
  `reload_config` returns `ReloadFailure::Auth` for 401/403, the publication
  gate records the port+secret fingerprint, and `sync_gateway_after_transition`
  reports the stored refusal without another HTTP attempt until the port or
  secret changes. Closing verification:
  `a_rejected_credential_is_not_retried_for_the_same_port_and_secret` and
  `a_rejected_credential_marks_the_failure_as_an_auth_refusal`.
- **F9 (R7) — CLOSED by REPAIR3.** `sync_gateway_after_transition` read
  `state.settings()` once before spawning the publication and cloned that
  snapshot into every retry, so a settings save during a failing attempt was
  overwritten by the older values on the next round. Remedy applied:
  `AppState.settings` is an `Arc<Mutex<Settings>>`; the fingerprint uses one
  snapshot, while each write and each catalogue read re-locks the shared value.
  Closing verification: `cargo xwin check` compiles the moved field, and the
  publication tests still pass with per-round snapshots.

- **F10 (R3) — CLOSED by REPAIR4.** The code called alias equality the point
  where the revision is "observably applied", which overstates what
  `/v1/models` can show: an unchanged catalogue already matches the expected
  set before the async reload runs, and an empty one does too. Remedy applied:
  the comments and the Codex message say "catalogue lists/converged" instead of
  "published/applied"; the two config GETs were audited and documented as
  unable to report reload completion; failed publications now back off per
  revision (15 s doubling to 5 min) instead of rewriting the file on every 5 s
  supervisor tick. Closing verification:
  `a_failed_publication_backs_off_within_the_same_revision` plus the 23
  publication tests.

### Out of scope (no impact found)

- `mark_synced` for the successful path stays where it is, because equality is
  the only bound available; it is documented as convergence, and
  `request_resync` covers a stale catalogue.
- `reload_config` now receives the bytes instead of reading `config.yaml`, which
  also removes the window where a concurrent settings save could make it adopt a
  different generation.
- Windows atomic publication is `write tmp + fs::rename` over the config path;
  fsnotify watches the directory, so the rename still produces an event for the
  target. After REPAIR2 that event is only the fast path — the explicit reload
  is the guarantee. No Windows host was available, so the rename/AV behavior is
  documented as residual, not measured.
- The engine's own `ERROR_NOTIFY_ENUM_DIR` overflow path is logged and drops
  events; it is now irrelevant to publication and was not patched.

## LOOP

- Repairs used: 7 (REPAIR1: F1 revert, F2 bookkeeping, F3 wording; REPAIR2:
  F4 v8 endpoint, F5 canonical layout, F6 message, F7 single snapshot;
  REPAIR3: F2 catalogue confirmation, F5 QoS root + v8 allowlist, F6 empty
  set, F8 auth ban, F9 fresh settings; REPAIR4: F10 no proof claim + retry
  backoff; REPAIR5: F11 digest completion contract, F12 serialized writes +
  superseded snapshots, F13 auth gate ordering/cooldown; REPAIR6: F14 settings
  merge + unconditional write, F15 start reloads after the catalogue await,
  F16 error-path restore + no auth block for a superseded snapshot; REPAIR7:
  forced disk restore + adopt identity guard).
- Findings open: none in the changed lines. Residual, not measured: Windows
  `rename`/AV/watcher timing (no Windows host in this session). Residual,
  blocking a release: the Windows/macOS engine and dist artifacts are outputs
  of earlier trees. The Windows blob contains the reload/digest symbols, but
  their behavior was not exercised on Windows and provenance was not
  regenerated for the final tree; the macOS blob and the dist executable are
  not tied to the current repair. Do not treat them as final.
- Residual window, documented not closed: `publish_attempt` checks
  `CONFIG_GENERATION` immediately before `mark_synced`, but the check and the
  atomic `fetch_max` are not one transaction. A config write that lands between
  them marks revision N synced while generation N+1 is on disk. Closing this
  needs the config write lock held across both operations (new gateway API),
  which was not added in this minimal repair. Impact is bounded to that
  instruction window; the next save/publication owns the newer generation, and
  a stale catalogue still triggers `request_resync`. It is not claimed solved.
- Residual window, documented not closed: the UI payload merge in
  `settings_set` still lacks a client-supplied revision/base. `before` is the
  server state at command entry, not the state the UI rendered; a field changed
  by another writer before the request began can still be overwritten by an
  old UI value that the user did not edit. Only a real revision/base contract
  would close it.
- Re-review: R1–R8 PASS on code-path, live-engine and patch-application
  evidence. R9 passes for the repaired write/reload paths, with the two
  residual windows above explicitly outside that claim. This record does not
  claim a Windows reproduction of the original screenshot.
- Gate after REPAIR7:
  - `cargo test --bin melontools` — see EVIDENCE for the exact run.
  - `cargo xwin check --target x86_64-pc-windows-msvc --tests` from
    `Windows/app/src-tauri` with
    `CARGO_TARGET_DIR=$HOME/Library/Developer/melontools-win/target`.
    Run it from that directory: `Windows/` has no `Cargo.toml`. The in-repo
    target dir cannot be used for this check: the external volume materializes
    AppleDouble `._*` files inside the generated Tauri permission tree, and
    `tauri-2.12.4/build.rs` panics on their invalid UTF-8. That is a filesystem
    artifact, not a code defect.
- Cumulative repair count for this record: 7 (the parent record's count stays 2).
