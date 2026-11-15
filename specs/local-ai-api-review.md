# Local AI API — independent review

- Date: 2026-11-06
- Reviewer: independent SpecLoop reviewer (not builder)
- Scope: `specs/local-ai-api-publication.md` R1–R5/C1–C5, `specs/local-ai-api-macos.md`,
  `specs/local-ai-api-windows.md`, `specs/local-ai-api-engine.md`
- Status: **PASS** — all required C gates have final evidence on the frozen tree. The one
  explicit limitation is that the Windows desktop app was not executed on native Windows.
- Mode: read-only review. No production code, spec, commit or user state was changed by the
  reviewer; this file is the reviewer-owned record.

## Final frozen fingerprints

| Surface | Value |
|---|---|
| root tracked diff | `95688f17b12b10c8de59c7ca2e52849a93bc360f7d3d8df4495c70428f32eae2` |
| macOS tracked diff | `4590b12e2c39bc6b5f7a50f6a0beafc831758ad02acbca933bc69cb1908000fd` |
| Windows tracked diff | `7bb74f3052cdf8420b2ec2c1115f4394383f56e53017024c6a619c82a1791783` |
| `MacOS/app/MelonTools/Codex/CodexGatewayService.swift` | `c56e61dad9f907436e11afc8fce531cf3181aacf76023dffb639d7bc3c7a9ebb` |
| `MacOS/app/MelonTools/LocalAI/LocalInferenceService.swift` | `23a4ca7f20cd85964775def4e8b9ce6982bad4f1b67f2f03e9370c78c1566c13` |
| `MacOS/app/MelonToolsTests/CodexGatewayEngineTests.swift` | `5d6183c5dbcf65697d7470a0f63a9cf6ac92b0b449e8de3262ef644fa8c13f83` |
| `Windows/app/src-tauri/src/gateway.rs` | `bdbfd99f588b116664333ab2211cd08b1c2d93ebb8c71ed04c87ce2ac6d982e9` |
| `specs/local-ai-api-windows.md` | `59a7c4a4992863ca617a5dd7b5e0bfe35ad9f763171187b4509b463014be000d` |
| engine baseline commit | `1f917e77c4562623aa49e9804d999524151a2f96` |
| publication baseline commit | `ab26028cb0b5efaf2c96aeb0ded20f3912d81e68` |

`git diff --check` on the final tree: **PASS** (exit 0). No whitespace errors or conflict
markers. The reviewer did not edit or rerun any production gate.

## Findings — closed

### F1 — CLOSED: publication retries force a replace

The previous blocker was that a retry regenerated the same YAML and was skipped as
idempotent, so a missed engine fsnotify event could leave `/v1/models` stale. Both platform
writers now distinguish explicit publication from ordinary coalesced settings/catalogue
writes:

- macOS: `CodexGatewayService.writeConfig(reason:force:)` passes `force` through
  `flushConfigWrite` into `writeConfigFile`; `lastWrittenConfig` is updated only after the
  actual replacement. The live publication hook uses `force: true` on every attempt and
  retry (`LocalInferenceService.performPublication`). `SecureFile.write` writes a hidden
  sibling temp with `O_EXCL 0600`, `fsync`, then `rename`; a failure unlinks the temp and
  preserves the destination. There is no in-place fallback.
- Windows: `write_config_forced` / `write_config_if_changed_forced` bypass the same-generation
  predicate, while `write_config` keeps the idempotent path for settings and catalogue
  updates. `publish_attempt` calls `crate::gateway::write_config_forced`. The replace is a
  temp file plus at most three bounded `rename` retries; a failed replace removes the temp,
  keeps the destination and leaves the generation cache unchanged. There is no `fs::write`
  in-place fallback.
- Regression tests replace an unchanged file and check the new content on macOS (inode
  replacement) and Windows, and cover add/remove generations. A failed forced write is
  asserted to preserve the destination and not populate the cache. These tests passed in
  the final runs (`CodexGatewayEngineTests` 9/9 on macOS; Windows forced-write tests in the
  433-pass suite).

### F2 — CLOSED: an unloaded/corrupt model-sources store cannot be a successful no-op

- macOS `ModelSourcesStore.load()` leaves `isLoaded == false` for an unreadable or
  undecodable file (a missing file is a legitimate empty first run). `writeConfig` retries
  that load and then `writeConfigFile` calls `loadedGuard()`; the guard throws the typed
  `ConfigError.modelSourcesUnavailable` before touching disk. Initial publication catches
  that error and calls `finishPublication` with a visible message. Retry writes use an
  explicit `do/catch` and surface “Local AI gateway config could not be rewritten …”; they
  do not use `try?`.
- `testWriterRefusesUnloadedSourcesBeforeTouchingDisk` uses a corrupt temporary store,
  asserts the typed refusal and that no config file is created.
  `testPublicationRetryWriteFailureIsVisible` makes the second write fail, asserts the
  visible error, exactly two write attempts and no success state.
- Windows rejects an empty gateway API key or management secret before writing, and any
  publication write failure is returned by `publish_attempt`; it reports a visible
  “gateway config could not be written” reason, does not mark the revision synced, and
  leaves the revision dirty for the supervisor. Tests cover the empty-key failure and the
  failed forced write.

### F3 — CLOSED: evidence is on the frozen tree

The previously stale 468/Release logs predated the repair. The final macOS full suite,
Release build and real E2E, and the final Windows full suite, targeted publication tests,
`cargo xwin check` and JS/Chromium checks were all run after the last production edits.
Counts and paths below are the final record, not an older binary.

## Criterion assessment

| Criterion | Verdict | Final evidence |
|---|---|---|
| C1 macOS | **PASS** | Full XCTest: **471 tests, 7 skipped, 0 failures, TEST SUCCEEDED**, `/tmp/melon-repair2-full.log`; the 7 skips are opt-in engine/UI fixtures and are not counted as C4. Release: **BUILD SUCCEEDED**, `/tmp/melon-repair2-release.log`, no errors. Real-model XCTest: **16 tests, 0 skipped, 0 failures**, `/tmp/melon-repair2-e2e-real.log`. The full log records the production writer test at 2.264 s and the three F1/F2 regression tests as passed. |
| C2 Windows | **PASS (host/cross-build; native Windows not run)** | `cargo test --bin melontools`: **433 passed, 0 failed, 1 ignored**; publication-targeted run: **7 passed**. `cargo xwin check --target x86_64-pc-windows-msvc --bin melontools`: exit 0, 2.54 s. `cargo xwin check --target x86_64-pc-windows-msvc --tests`: exit 0, 4.61 s, so the cfg-unix portability fix and the whole test module compile for the Windows target. All ten JS/static/browser harnesses and the isolated headless-Chrome DOM smoke passed. This is not native Windows execution; see the limitation below. |
| C3 engine | **PASS** | Engine source is unchanged from baseline `1f917e77…`; its full Go suite, Windows cross-build and Python syntax remain valid. Both tracked native fixtures (`macOS` and `Windows`) passed fixed-gateway `--startup-race` and `--start-published`, two cycles per fixture, with add/remove/chat/proxy-bypass and authenticated `/v1/models`. The final harness/pycompile parent job `bash-570898f0f4694566` exited 0. |
| C4 real runtime | **PASS** | Parent job `bash-d9d1b81087cb4918` exit 0: both native fixtures, **two real Qwen load/chat/unload/remove cycles each**, actual loaded-model presence, direct proxy-bypass chat, route removal and post-removal rejection; no skips. macOS also has the fresh 16/0 real-model XCTest. No opt-in skip counts toward this gate. |
| C5 review | **PASS** | `git diff --check` exit 0; final fingerprints and fresh gate records are above; F1/F2/F3 are closed; R5 is satisfied by the test design and the evidence checks below. The only open item in the Windows builder record is the non-blocking naming question about reusing `publicationError` for catalogue errors (the error is visible; it does not hide a write/publication failure). |

### R1–R5

| Requirement | Verdict | Reason |
|---|---|---|
| R1 publication | **PASS** | Forced atomic replacement on every publication retry on both platforms; real fixtures show the alias appearing in authenticated `/v1/models`, chat reaching the loaded model with the relay token/port/upstream ID/proxy bypass. |
| R2 visibility/lifecycle | **PASS** | Start/stop/reload/unexpected-exit paths update publication; corrupt store and config write failures are visible and do not mark success; a gateway started after the model is covered by startup/publication reconciliation. |
| R3 Connections | **PASS** | Local AI is represented in Connections and excluded/included truthfully by the connection check on both platforms; the JS/Chromium harnesses passed on the frozen tree. |
| R4 Models UI | **PASS** | Active local aliases appear in the API model list and update after lifecycle actions; local-only configurations work without an OAuth/cloud account; the Chrome DOM smoke asserts Connections counts and the Models subtab. |
| R5 safety/regressions | **PASS** | Test configs use isolated temporary directories and loopback ports; existing GGUF is read-only; the reviewer saw no credentials in logs/evidence; no commit, install or app replacement was performed. The three new macOS writer tests use isolated temp roots, and the real E2E uses a UUID temp root plus free loopback ports. |

## Explicit limitation

**Native Windows was not executed.** Neither the reviewer nor the parent ran the Windows
desktop binary, WebView2 UI or a Windows-host runtime. C2 is therefore a Windows-target
compile check plus Rust tests executed on the macOS host and JS/Chromium DOM checks, not a
native Windows runtime claim. C4 exercised both tracked native configs through an isolated
engine on macOS; it does not replace a native Windows smoke. This limitation is recorded
rather than waived, and no part of this record claims native Windows execution.

Non-blocking: the Windows record already states that a failed `refresh_catalog` reports
through `publicationError`; the error remains visible and does not suppress or misreport a
config write, so it is a UX naming question, not a correctness/safety blocker.

## Verdict

**PASS — GO on the frozen reviewed tree.** F1 (retry suppression) and F2 (silent unloaded
store) are fixed and covered by passing regression tests; C1–C5 have final evidence on the
same fingerprints; R1–R5 pass. Ship only with the explicit limitation that native Windows
runtime execution is still untested.
