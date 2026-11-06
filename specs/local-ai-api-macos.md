# Local AI API publication — macOS lane

## SPEC

- Phase: BUILD complete; REPAIR 1 applied (2026-11-06).
- Parent spec: `specs/local-ai-api-publication.md` (not edited by this lane).
- Baseline revision: `ab26028cb0b5efaf2c96aeb0ded20f3912d81e68`.
- Engine baseline: `1f917e77c4562623aa49e9804d999524151a2f96`.
- Scope: macOS app publication, Connections/Models presentation and the XCTest
  isolation needed to test them. Shared CLIProxyAPI sources and the shared spec are
  parent-owned and were not modified.
- Cumulative repair count: 1.

### Requirements

- **R1 Publication.** A confirmed local load publishes the canonical `local/<id>` alias
  to the running gateway's authenticated `/v1/models`, using the effective runtime
  port, internal token and direct loopback bypass.
- **R2 Lifecycle.** Start, stop, delete, crash and relaunch rewrite publication.
  Stopped or stale models are not left advertised. Publication/catalog errors are
  visible and a stale `Ready` registry row is normalized after relaunch.
- **R3 Connections.** The Local AI card distinguishes downloaded vs actually
  published models, and shows engine/publication failures instead of a misleading
  green pill.
- **R4 Models.** The macOS model list is refreshed from the same effective-source
  projection used to write the gateway config.
- **R5 Safety.** Tests use temporary directories and loopback ports. The installed
  app, live gateway config, API key and developer keychain are not test fixtures.

### Implementation

- `Codex/ModelSources.swift`: pure `localAISource(...)` and `effectiveSources(...)`
  projection. Only `.ready` models contribute an alias; `gatewayYAML` remains the
  single production generator for the gateway block.
- `LocalAI/LocalInferenceService.swift`: verified publication state machine with an
  injectable `PublicationHooks` seam. Publication retries until the gateway serves
  every expected alias, exposes `publicationError`, and refuses to publish an empty
  expectation. Test teardown awaits the pending task before live hooks are restored.
- `Codex/ProviderDiagnostics.swift`: Local AI row requires ready aliases, reports
  `publicationError` even when the gateway answers, and does not count installed-only
  models as API-ready.
- `Views/Codex/ModelSourcesView.swift`: `LocalAICardState` reports Downloaded
  (`.installed || .ready`) separately from Ready (`.ready` only), plus an independent
  publication-error state. The pill is not green merely because the engine process is
  running.
- `LocalAI/LocalModelStore.swift` and `LocalAI/LocalPaths.swift`: test-only callback
  reload/replace and base-path override; no normal-runtime path change.
- `Codex/CodexGatewayService.swift` and `MelonToolsApp.swift`: XCTest host isolation.
  Test defaults do not persist the gateway port/key, real views and singletons are not
  built by the test host, and test-host termination does not flush the real stores.

## EVIDENCE

### Full XCTest gate

Run from `MacOS` on the final tree with a unique DerivedData path (the shared
`~/Library/Developer/MelonTools` database is used by a concurrent lane):

```
xcodebuild -project app/MelonTools.xcodeproj -scheme MelonTools \
  -configuration Debug -derivedDataPath "/tmp/melon-repair2-full-A803ABC1-6E34-4CE3-BD0B-B311410F9F07" test
```

Result: **471 tests, 7 skipped, 0 failures, TEST SUCCEEDED** (16.480 s, log
`/tmp/melon-repair2-full.log`). The seven skips are the six opt-in engine tests in
`LocalAIEngineIntegrationTests` (16 executed, 6 skipped) and one fixture exporter in
`LocalAITests`; they are not counted as C4 evidence. The 471 total includes the three
REPAIR2 regressions below.

### Real runtime C4 (no skips)

The same class was run with the opt-in sentinel `/tmp/melon-local-ai-e2e` and the
existing read-only GGUF. The sentinel was created for this run and removed after it;
the test host does not inherit arbitrary `xcodebuild` environment variables:

```
xcodebuild ... test -only-testing:MelonToolsTests/LocalAIEngineIntegrationTests
```

Result: **16 tests, 0 skipped, 0 failures** (17.927 s, log
`/tmp/melon-repair2-e2e-real.log`).
It exercises real `llama-server` load/generate/stop, crash normalization, switching,
metrics and loading state. This is the actual bundled runtime path, not an in-memory
stub.

### App-path gateway publication (C3)

`testProductionWriterPublishesAndRemovesRoutesOnARealGateway` passed (1.25 s) against
a real temporary CLIProxyAPI on random loopback ports. The test starts with an
installed-only model, confirms the alias is absent, publishes a `.ready` model using
the production `effectiveSources`/`gatewayYAML` writer, asserts the alias appears in
the authenticated `/v1/models`, then removes the route and asserts it is gone. Retry
is allowed but not required; a separate deterministic hooks test covers the retry.

### Cancellation race (REPAIR 1 tiny fix)

`performPublication` now returns before capturing `publicationHooks` or calling
`writeConfig` when `Task.isCancelled` is already true. This closes the queue race
where a task cancelled by a newer publication or by teardown could start later and
write through restored live hooks. The deterministic test
`testPublicationCancelledBeforeStartingDoesNotWrite` creates the task, cancels it
before any suspension, awaits it, and asserts zero writes/catalog syncs/served calls.
A mutation check (guard temporarily removed) failed with `writes == 1`; the guard
restored the pass. The teardown await remains as defence in depth.

### R5 teardown isolation fix

The E2E stop assertion no longer reads `ModelSourcesStore.shared.effectiveSources`;
it calls the pure `ModelSourcesStore.effectiveSources(base: [], ...)` seam. This
prevents a test assertion from loading, migrating, or saving the user's 192 KB
source store. Teardown no longer calls `reloadFromDiskForTesting()` after clearing
the override. It clears the rows with `LocalModelStore.replaceModelsForTesting([])`
while the temp root is still installed; that seam cancels the pending metadata
repair task, then the override is cleared. No registry read, repair, or save can
target the real vault during teardown. The real `model-sources.json` and
`metadata/models.json` SHA-256 values below stayed byte-identical across the full and
E2E runs.

### Isolation and live-state check

Before and after the final E2E runs:

- live `config.yaml` at the final post-gate check: SHA-256
  `ad6b3016d2675d9bcea83f202db9321fbf2583173649e25d70327ac6b7a644bf`, mode 600,
  2438 bytes, mtime `2026-11-06T11:56:58` (before this REPAIR2 gate; not written by
  these tests). The earlier `4011bd11…` value is the historical pre-test copy from the
  incident below;
- live `api-key` SHA-256 `d1a7d409ceb8ebaceb5a85d79eddcd52cd1b0b3152dbabc9333adba9a239572b`,
  mode 600, 30 bytes — unchanged;
- no `melon-local-ai` alias and no test key in the live config (both grep counts 0);
- real `model-sources.json` SHA-256
  `d132374c56e8df9fddeda6138f2d0f5890a8bfbce7f7037dc7afc5e08d2660ae`, mode 600,
  192484 bytes — unchanged; the E2E stop assertion now builds from a pure empty
  base instead of reading this store;
- real `metadata/models.json` SHA-256
  `9d065859e814835b9adffa53861441f0955bc47ae4d77f169fd79a159a9fa76e`, 1928 bytes,
  mode 644 — unchanged; teardown clears test rows in memory while the temp root is
  installed, cancels pending metadata repair, and never reloads the real registry;
- UserDefaults export diff across a test-host launch: **no added, removed or changed
  keys**;
- no Keychain prompt; test `LocalModelStore` never loads the real Keychain.

**Honest incident record.** Before the teardown ordering fix, one real E2E run did
rewrite live `gateway/config.yaml` with the test sentinel key and a plain management
secret (mutated SHA-256
`c8b88ba133895aa23398bc8461daa2db03ad67956e7e81a2a61d1ba7f55f2f81`; an earlier run
produced `2548ff35…`). The cause was `stop()` scheduling an asynchronous publication
after `resetPublicationForTesting()` had restored live hooks. The exact known pre-test
copy (SHA `4011bd11…`) was restored with mode 600; the temporary copy was deleted
after the restore, and subsequent runs proved no further mutation. No API key or management
secret value is reproduced here. This was a test-host isolation defect, not production
publication behavior.

### REPAIR2: forced publication writes and typed source errors

- `CodexGatewayService.writeConfig(force:)` and `flushConfigWrite(force:)` default to
  the existing debounced/idempotent behavior. The Local AI publication hook is the
  only caller that passes `force: true`, so a retry in the same generation still
  replaces `config.yaml` (the gateway's watcher may have missed the first event).
- `writeConfigFile(_:to:lastWritten:force:loadedGuard:)` is the production actual
  writer seam. It takes an explicit URL and last-written cache, calls the loaded-store
  guard before touching disk, skips an unchanged generation unless forced, and uses
  `SecureFile.write` otherwise. Tests use temporary URLs; no live gateway path or
  live `ModelSourcesStore.shared` is touched.
- If the sources store is still unloaded after the retry `load()`, the helper throws
  `CodexGatewayService.ConfigError.modelSourcesUnavailable`; `writeConfig` also logs
  the refusal. A failed rewrite inside the publication retry loop is no longer
  discarded with `try?`: it sets `publicationError` and returns instead of letting a
  matching previous catalogue clear the error.

Focused regression run (`CodexGatewayEngineTests`): **9 tests, 0 failures**, including
same-generation forced replace (inode changes), forced add and forced removal,
unchanged skip, changed add/remove writes, a corrupt isolated `ModelSourcesStore`
throwing the typed error before any file exists, and a publication retry failure that
stays visible without a second `/v1/models` read.

Final source hashes:

- `CodexGatewayService.swift`
  `c56e61dad9f907436e11afc8fce531cf3181aacf76023dffb639d7bc3c7a9ebb`
- `LocalInferenceService.swift`
  `23a4ca7f20cd85964775def4e8b9ce6982bad4f1b67f2f03e9370c78c1566c13`
- `CodexGatewayEngineTests.swift`
  `5d6183c5dbcf65697d7470a0f63a9cf6ac92b0b449e8de3262ef644fa8c13f83`

### Release build gate

```
xcodebuild -project app/MelonTools.xcodeproj -scheme MelonTools \
  -configuration Release -derivedDataPath "/tmp/melon-repair2-release-BD34B7E1-F565-4FB8-A767-487C83E5A7E7" build
```

Result: **BUILD SUCCEEDED** (log `/tmp/melon-repair2-release.log`). Only pre-existing
`onChange(of:perform:)` deprecation warnings were reported.

### Known limits

- The installed `/Applications/Melon Tools.app` was inspected read-only and was not
  replaced. The proof runs the app target's production publication code inside the
  XCTest host, not the installed GUI.
- The engine source tree and shared publication spec were not edited.

## FILES

- `MacOS/app/MelonTools/Codex/ModelSources.swift`
- `MacOS/app/MelonTools/Codex/ProviderDiagnostics.swift`
- `MacOS/app/MelonTools/Views/Codex/ModelSourcesView.swift`
- `MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift`
- `MacOS/app/MelonTools/LocalAI/LocalModelStore.swift`
- `MacOS/app/MelonTools/LocalAI/LocalPaths.swift`
- `MacOS/app/MelonTools/Codex/CodexGatewayService.swift`
- `MacOS/app/MelonTools/MelonToolsApp.swift`
- `MacOS/app/MelonToolsTests/LocalAITests.swift`
- `MacOS/app/MelonToolsTests/ProviderDiagnosticsTests.swift`
- `MacOS/app/MelonToolsTests/LocalAIEngineIntegrationTests.swift`
- `MacOS/app/MelonToolsTests/CodexGatewayEngineTests.swift`
- `MacOS/app/MelonToolsTests/Fixtures/local-ai-gateway.yaml`
