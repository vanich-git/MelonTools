# Local AI: a failed reload must never mark the catalogue as published

## SPEC

### Objective

A Local AI model that the runtime reports as `ready` must end up in the gateway
`/v1/models` catalogue, or the UI must show the concrete publication failure.
On Windows a ready model never reached the API while `publicationError` stayed
empty, so the connection card showed "Local AI: в API нет local/…" with no
reason and no retry.

### Current behaviour (defect)

`local_ai/commands.rs::sync_gateway_after_transition` runs `publish_attempt`.
Its write phase calls `gateway::write_config_forced` and then
`gateway::reload_config`. When the reload returns `Err`, the closure probes
`gateway::health`; if the probe is false (engine busy starting, a transient
loopback failure, a management endpoint that does not answer) it returns
`Ok(None)`:

```rust
Err(error) => {
    if !crate::gateway::health(settings.port, &settings.api_key).await {
        Ok(None)
    } else { ... }
}
```

`Ok(None)` means "published": `publish_attempt` calls
`reporter.mark_synced(revision)`, clears `reload_error`, releases the
publication gate and never retries that revision. An empty catalogue is then
indistinguishable from a published one. Every later `local_ai_runtime_status`
poll sees no pending revision and does nothing, so the model stays out of the
API for the life of the process, with no error text.

### Desired behaviour

1. A non-empty expected catalogue is published only when the poll actually
   finds every `local/*` alias in `/v1/models`. A failed reload with an
   unanswered health probe is not evidence of publication.
2. The empty case stays quiet: when no model is servable (`expected` is empty)
   and the engine does not answer, there is nothing to publish, and the next
   engine start rewrites `config.yaml` anyway.
3. The revision stays pending on a failed publication, so the UI status poll
   retries it; the retry succeeds as soon as the engine answers.
4. The UI keeps showing the engine error through `publicationError`.

### Scope

- `Windows/app/src-tauri/src/local_ai/commands.rs`: the reload closure in
  `sync_gateway_after_transition`, one small decision helper, tests.
- No change to `gateway.rs`, `catalog.rs`, the engine binary, the UI, or the
  publication retry policy (`3` rounds x `20` polls x `250 ms`).

### Assumptions

- The management reload endpoint itself works: verified against the shipped
  engine (`PUT /v0/management/config.yaml` -> `200 {"ok":true}` and
  `/v1/models` gains the new `local/*` entry within one second).
- `health` is a liveness probe (`GET /v1/models`), not an acceptance probe; a
  `401`/`404` reads as "not healthy", which is exactly why it cannot decide
  that a catalogue was published.
- A stopped engine legitimately leaves `expected` empty; `gateway::start`
  rewrites the file before the engine reads it.

### Requirement IDs

- R1 `expected` non-empty + reload `Err` => never `Ok(None)`; the poll is the
  only source of "published".
- R2 `expected` empty + reload `Err` + health false => `Ok(None)` (nothing to
  publish, no spurious error on a stopped engine).
- R3 `expected` non-empty + reload `Err` + health true => `Ok(Some(error))`
  (unchanged, engine text preserved).
- R4 A publication that never observes the expected aliases keeps the
  revision pending and sets `publicationError`.
- R5 The decision is unit-tested and the existing 440-test baseline stays
  green.
- R6 No file outside the scope changes; `catalog.rs` stays at HEAD.

### Acceptance criteria

- `cargo test` (macOS target dir) passes with the new tests.
- `cargo xwin build --release --target x86_64-pc-windows-msvc` succeeds.
- Windows portable and NSIS installer rebuild, hashes refresh in the delivery
  folder.
- The diff adds no `Ok(None)` on a non-empty expected catalogue.

### Check plan

| Check | Required | Command |
| --- | --- | --- |
| Unit + integration suite | yes | `cargo test --offline` in `Windows/app/src-tauri` with `CARGO_TARGET_DIR=$HOME/Library/Developer/MelonTools/target` |
| Windows cross build | yes | `cargo xwin build --release --target x86_64-pc-windows-msvc` |
| Installer | yes | `makensis` over the generated `.nsi` |
| Delivery manifest | yes | `shasum -a 256` + `SHA256SUMS.txt` |
| Diff scope | yes | `git diff --stat` limited to `local_ai/commands.rs`, `specs/…` |

### Done criteria

R1-R6 pass, the delivery folder holds the new artifacts, and no upload,
commit, push or installed-app update happened.

## EVIDENCE

- User screenshots: Local AI card `2 МОДЕЛИ / 0 ДОСТУПНО МОДЕЛЕЙ`, connection
  table `Local AI: РАБОТАЕТ`, `auth: НЕ ОПУБЛИКОВАНО`, `models: 0`, and the
  check text `Local AI: в API нет local/unsloth-qwen3.5-2b-gguf-qwen3.5-2b-bf16`.
- `mt-actions.js` `localAiConnectionsCheck` tests `publicationError` before
  `missing`, so the `missing` text proves `publicationError` was empty while a
  `ready` model was absent from the catalogue: the app had marked the revision
  synced without publishing it.
- Engine experiment (`$HOME/Library/Developer/melontools-engine-test`): the
  shipped engine started with a config that has one `openai-compatibility`
  model; `GET /v1/models` returned `local/unsloth-…`; `PUT
  /v0/management/config.yaml` with a second model answered
  `200 {"changed":["config"],"ok":true}` and `/v1/models` listed both entries.
  The management path, secret format and YAML contract are therefore correct;
  the defect is the client-side success decision.
- `[gateway] config.yaml written` and the engine `200` prove the write path;
  no engine-side rejection exists to explain an empty catalogue, which leaves
  the swallowed `Err` as the only silent path.
- Timing: `gateway_client()` uses a 3 s timeout. A model start keeps the
  engine busy loading weights, so `reload_config` and the `health` probe can
  both time out; the old branch read that as "nothing happened" and marked the
  revision synced.
- Required checks:
  - `cargo test --offline` -> `442 passed; 0 failed; 1 ignored` (63.78 s).
  - `cargo xwin build --release --target x86_64-pc-windows-msvc` -> `Finished
    release profile in 30.93s` (only the expected `LNK4099` pdb warnings).
  - `Windows/build-windows.sh` -> `done`, portable 41,783,808 bytes, setup
    28,223,448 bytes.
  - Marker `gateway reload failed while no local model is servable` present in
    the shipped PE (`strings` match count 1).
  - `SHA256SUMS.txt` refreshed: setup
    `cb4dac57ec110aa7aea5e1ddbe45dca5286bb025a6ff3bdd48524bc5168d462e`,
    portable `e9cca3332e8a356cfa70688307011ba3be322eb77fe3787e46d9027bd564ea88`.

## REVIEW

### Findings

- F1 (root cause, fixed): the write phase returned `Ok(None)` whenever the
  reload failed and `health` was false. `Ok(None)` calls `mark_synced`, clears
  `reload_error` and releases the gate, so no later status poll retried the
  revision and the card had no error to show. A model start is exactly the
  moment the engine is busy loading weights: a 3 s `reload_config` or `health`
  timeout there produced the silent success. Fixed by
  `reload_failure_is_harmless` (R1-R3).
- F2 (verified, not a defect): the management endpoint, YAML shape, secret
  header and content type are correct against the shipped engine (200, the
  catalogue gains the alias immediately). No change made.
- F3 (verified, not a defect): the UI tests `publicationError` before
  `missing`, so the user's `Local AI: в API нет …` line proves the error was
  empty, i.e. the swallowed `Ok(None)` path, not a rejected file.
- F4 (out of scope, recorded): `gateway::start`'s adopt branch rewrites
  `config.yaml` without calling `reload_config`. It cannot produce the reported
  symptom (startup normalizes `Ready` rows to `Installed`), and no publication
  revision is pending then, so it is left unchanged.
- F5 (limitation): no Windows host or VM is available, so the end-to-end
  reproduction of F1 relies on the timeout path, the code, the engine
  experiment and the user's screenshots; the rebuilt binary is the first
  artifact that can confirm it on Windows.

### Requirement verdicts

| ID | Verdict | Evidence |
| --- | --- | --- |
| R1 | pass | `reload_failure_is_harmless(true, false) == false`; the closure returns `Ok(Some(error))` |
| R2 | pass | `reload_failure_is_harmless(false, false) == true` |
| R3 | pass | `reload_failure_is_harmless(true, true) == false`, text preserved |
| R4 | pass | `an_unanswered_catalogue_keeps_the_revision_pending` (pending 9, "could not be queried") |
| R5 | pass | 442 passed / 0 failed / 1 ignored |
| R6 | pass | diff limited to `local_ai/commands.rs`; `catalog.rs` untouched |

### Scope check

Only `Windows/app/src-tauri/src/local_ai/commands.rs` and this record changed
in this round. No commit, push, upload, app install or app update.

## LOOP

- Repairs: 0 (one BUILD, one REVIEW, no oscillation).
- Baseline: 440 passed / 0 failed / 1 ignored -> 442 passed with the two new
  tests.
- Reviewer isolation: self-review; no independent reviewer context was
  available, so strict-mode independent review cannot be claimed.
- Phase: DONE (SPEC, BUILD, REVIEW complete).
