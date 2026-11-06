# Local AI API publication — SpecLoop

## SPEC

- Phase: COMPLETE / SPECLOOP PASS (2026-11-06), after 2 cumulative repairs; shared spec saved before implementation, compatibility repair explicitly authorized after concurrent idempotency changes.
- Baseline revision: `ab26028cb0b5efaf2c96aeb0ded20f3912d81e68`.
- Initial tracked-diff SHA-256: `29c2aa662bc3e5f80d9bcc227d3d441dbde192037c91b1815757b652ae5cef96`.
- Engine baseline: `1f917e77c4562623aa49e9804d999524151a2f96`; initial tracked-diff SHA-256 `e7a07d55ab02d83c25a78a62ef49f31ac05f8fd0c25546a4c706c9033bad8916`.
- Mode: default, independent platform builders and independent final reviewer.
- Cumulative repair count: 2 (maximum 3).

### Objective and current behavior

User reports that successfully started local models are missing from the gateway API, Connections checks and Models on both macOS and Windows. Earlier test claims did not establish end-to-end publication. Existing unrelated/previous feature changes are part of the baseline and must remain intact.

### Requirements / acceptance criteria

- **R1 Publication:** after a confirmed model load, its canonical `local/…` alias is present in the actual gateway's authenticated `/v1/models`; chat through the gateway reaches the running model. Publishing must use the effective runtime/relay port, correct upstream model ID, internal token and proxy bypass.
- **R2 Lifecycle:** start, stop, reload/settings restart and unexpected runtime exit update publication and visible model lists; stopped/failed models must not remain callable-looking stale API entries. Publication/config errors must be visible, not silently treated as full success. A gateway started after the local model must include it too.
- **R3 Connections:** Local AI is represented in Connections and included by the connection-check action on both platforms; checks distinguish running/reachable, stopped/not-ready and errors truthfully without an external API key or account.
- **R4 Models UI:** the API model list includes active local models, uses their canonical aliases, and updates after lifecycle actions without restarting the app. Local-only configurations work without an OAuth/cloud account.
- **R5 Safety/regressions:** preserve cloud providers, routing, saved settings, models/weights, accounts and current unrelated edits. Do not publish, commit, deploy or replace installed applications as part of this debugging request. Test processes/configs use isolated temporary directories and loopback ports. No credentials in logs or evidence.

### Scope and assumptions

Fix the smallest coherent platform integration and only change the shared engine if demonstrated necessary. Version remains 6.0.0-rc.3 unless the user requests another version. Runtime/router health is not equivalent to a loaded model. The app currently running and user configuration are inspected read-only; isolated tests may load the existing GGUF file read-only.

### Required check plan

- **C1 macOS:** targeted regression tests for gateway source generation, lifecycle publication and Connections/model catalog; full default XCTest gate; Debug/Release compile as needed to validate changes.
- **C2 Windows:** Rust regression/full host tests, affected JS semantic/Chromium checks and static checks; Windows x86_64 compile check.
- **C3 Real gateway:** isolated real CLIProxyAPI (not an in-memory registry mock), native generated config fixtures from both platforms; verify authenticated `/v1/models`, chat forwarding, add/remove hot reload, local-only configuration, internal authentication and loopback proxy bypass with a deterministic local upstream. Include JSON-safe escaping of model IDs/names when relevant.
- **C4 Real runtime:** run a real llama-server with the existing GGUF in an isolated directory; confirm actual loaded-model presence, successful gateway chat and removal after stop. Record actual commands/results and any limitations explicitly. No opt-in skip counts as this gate passing.
- **C5 Review:** independent reviewer reads this record, actual relevant diff and evidence from disk; every R/C must be PASS or explicitly BLOCKED/FAIL. `git diff --check` on final state; fingerprints refreshed on every phase/repair. Required checks cannot be weakened to force PASS.

### Done criteria

R1–R5 and C1–C5 pass on the final state with no open correctness/safety findings. If required infrastructure is unavailable, report SPECLOOP BLOCKED and exact next action rather than claiming the bug fixed in shipping builds.

## EVIDENCE

### DISCOVER baseline

- Installed macOS app/gateway are running; no llama-server process at initial inspection.
- Read-only summary of the user registry showed one `local/qwen3.5-2b-bf16` model in `installed` state; live gateway config contained no `melon-local-ai` source. This snapshot alone does not reproduce the user's prior successful Start.
- Existing tests exercise Local AI runtime and YAML strings separately; a real gateway publication gate is needed.
- Engine supports v8 `api-keys.openai-compatibility` and `keys` schema; no schema change is presumed without reproduction.
- Engine Git emits AppleDouble pack-index warnings on this volume; Git commands still exit 0. Avoid broad cleanup of unrelated files.

### Parent integration probes (BUILD; historical counts retained)

Later platform gates and Repair 2 evidence supersede the intermediate counts/fingerprints in this section. Do not use these older runs to certify post-idempotency code.

- `python3 scripts/test_local_ai_gateway.py --engine MacOS/build/cliproxyapi --fixture /tmp/melon-local-ai-schema-probe.yaml`: initial attempt failed when configuration was replaced immediately after HTTP readiness. This is retained as startup-race evidence, not dismissed as a flaky test.
- Same test with explicit watcher-start log readiness: PASS, two add/remove cycles, authenticated chat through a deterministic upstream despite an unavailable global proxy; incorrect client token rejected.
- Same test with `--start-published`: PASS; initially configured local source and subsequent hot reloads work.
- `python3 scripts/test_local_ai_runtime_gateway.py --engine MacOS/build/cliproxyapi --runtime MacOS/app/Resources/runtime/llama-server --model <existing-read-only-GGUF> --fixture /tmp/melon-local-ai-schema-probe.yaml`: PASS; actual Qwen GGUF loaded in a temporary router, real gateway chat succeeds in two publication cycles, model unload confirmed. This schema probe is not yet native-platform fixture coverage.
- Python syntax check PASS; existing release-checksum unit suite 20/20 PASS; current root `git diff --check` PASS.
- Native Windows fixture `Windows/app/tools/fixtures/local-ai-gateway.yaml`: real fixed gateway `--startup-race` PASS and real Qwen runtime + fixed gateway PASS, two cycles each, including rejection after route removal. Fixture generated-output equivalence is being checked by the Windows builder.
- Fixed engine `/tmp/melon-local-ai-engine-test`: parent `--startup-race` PASS after pre-fix deterministic FAIL; real Qwen runtime regression PASS again. Durable fix and engine tests recorded separately in `specs/local-ai-api-engine.md`.
- Both tracked native fixtures (macOS and Windows) passed fixed gateway `--startup-race` and `--start-published`, two cycles per fixture. Strengthened C4 also passed for both: each cycle loads the real GGUF, checks returned model identity and non-empty chat, unloads it, removes the route, and waits for alias absence before checking 400/404 with the alias named in the error body. Router exits in cleanup. These standalone tests still complement, not replace, app-path convergence tests.
- Real headless Chrome DOM smoke (`Windows/app/tools/local-connections-browser-check.js`) PASS with deterministic mocked API and isolated browser profile: visible Connections card/check, Ready/missing/stale/publication-error verdicts, Models removal/navigation, zero uncaught page errors. This is real Chromium rendering/input, not Windows WebView2/native backend execution. First attempt correctly failed because onboarding intercepted the click; the test now dismisses onboarding via production action.
- Continuation verification (2026-11-06): final Windows tracked diff unchanged (`8a0c0b927c902ab669841a7d0bf3d37809051c34722ad28cb6e0a428e1f157c9`); parent reran `cargo test --bin melontools` (427 passed, 0 failed, 1 fixture exporter ignored), `cargo xwin check --target x86_64-pc-windows-msvc --bin melontools` (exit 0), all ten JS/static/browser harnesses and headless Chrome DOM check (PASS). Chrome also asserts Connections counts 1/1 → 0/0 and the Models subtab, not only the section. C3 both fixtures repeated with `--startup-race` and `--start-published`: eight cycles PASS. Python syntax PASS.
- macOS builder final gate: full XCTest 463 tests / 7 opt-in skips / 0 failures; targeted 32 / 6 skips / 0 failures; opt-in real runtime class 15 / 0 skips / 0 failures; production writer → real temporary gateway add/remove PASS; Release build PASS. Details and test-host isolation incident/repair are in `specs/local-ai-api-macos.md`. Final runs preserved live config SHA/mtime, API-key SHA/mtime and UserDefaults values. Installed app not replaced.
- Parent deterministic Go startup watcher tests repeated after freeze: PASS. Fixed engine also cross-built as Windows/amd64 PE without packaging (`/tmp/melon-local-ai-engine-windows-test.exe`, SHA-256 `7aba21df711140b86989e2922245ad534ddac2a6894fdb3101c3f9306d36dfba`). This is compilation evidence, not execution on Windows.
- Independent frozen-state review remains required. Reviewer identified R5 test-host persistence risks (defaults, API key, registry, model sources and delayed teardown publication); builder repaired these before final E2E. A previous opt-in test did alter live gateway config via a delayed publication task; builder reports restoration from the exact pre-test copy and subsequent hash/mtime stability. Final C5 must audit this isolation rather than assume test hooks alone make it safe.

### Repair 2 final verification (supersedes earlier platform counts)

- macOS frozen tracked diff: `4590b12e2c39bc6b5f7a50f6a0beafc831758ad02acbca933bc69cb1908000fd`. Parent read `/tmp/melon-repair2-full.log`: 471 tests, 7 intentional opt-in skips, 0 failures, TEST SUCCEEDED. `/tmp/melon-repair2-e2e-real.log`: 16 tests, no skips, 0 failures, TEST SUCCEEDED; real-gateway production publication add/remove passed in 2.264 s. Release BUILD SUCCEEDED (`/tmp/melon-repair2-release.log`, unique DerivedData). Focused actual-writer class: 9 tests, 0 failures. The first attempted opt-in E2E had six skips because its sentinel was absent and was not counted; the real-model rerun above has zero skips.
- Windows final frozen tracked diff: `7bb74f3052cdf8420b2ec2c1115f4394383f56e53017024c6a619c82a1791783`. Builder reports fresh full Rust 433 passed, 0 failed, 1 fixture exporter ignored; publication tests 7 passed; Windows x86_64 MSVC cross-check `--bin melontools` exit 0 (2.54 s), plus `--tests` exit 0 (4.61 s). The last test-only correction gates the entire Unix permission-denial case, leaving the rename-failure case cross-platform. Earlier Windows hash `e3a396…` is superseded. Actual-writer regressions cover identical forced add/remove writes, write failure without cache update, rename failure preserving destination and cleaning temporary file. No native Windows execution claim.
- Parent repeated C3 after the compatibility repair: both native config fixtures, startup-race plus initially published source, four add/remove/chat/proxy-bypass cycles PASS. Connections semantic harness and isolated headless Chromium DOM smoke PASS. Parent then repeated all ten JS/static harnesses plus Chromium and Python syntax on the repaired tree (job `bash-570898f0f4694566`, exit 0). Fresh C4 `scripts/test_local_ai_runtime_gateway.py` with both native fixtures and the existing Qwen GGUF also passed four real load/chat/unload/remove cycles (job `bash-d9d1b81087cb4918`, exit 0); every removed alias was rejected after catalogue convergence. All parent background jobs collected. Engine diff remained `2894664549607550c4496cdc14fc4725580a72bd60328b9b8d83d7e5cee5e431`; its full Go suite and Windows cross-build remain valid because engine source has not changed.
- Parent final frozen root tracked diff snapshot: `95688f17b12b10c8de59c7ca2e52849a93bc360f7d3d8df4495c70428f32eae2`; includes pre-existing dirty work, excludes untracked artifacts listed below. `git diff --check` PASS. Independent final read-only review `67bdab94-df63-4b90-abb8-7e6d51a02e87` returned PASS on these exact fingerprints: R1–R5 and required C1–C5 all PASS, with native Windows execution explicitly excluded. Reviewer artifact `specs/local-ai-api-review.md` SHA-256 `7dc167948f403c616d47e8dad3c61f61d6b7cab0f3664e1c427ba85e80dcb803`. Parent independently re-read the artifact and recomputed matching root/Mac/Windows fingerprints and `git diff --check` after verdict. Earlier BLOCKED review is superseded; no source changes followed final freeze.

## REVIEW

Independent read-only reviewer `67bdab94-df63-4b90-abb8-7e6d51a02e87` assigned. Engine fix independently reviewed and scoped/full Go suites passed. Preliminary findings require REPAIR 1:

- F1/R5: macOS in-place config write sacrifices atomicity; its inode rationale is contradicted by real repeated atomic hot reload. Restore atomic `SecureFile.write`.
- F2/R1,R2: fixture/hook tests do not prove actual Ready filter → native source → gateway convergence. Add production seams and lifecycle/native integration tests on both platforms; cover relaunch stale Ready normalization.
- F3/R3: ensure downloaded/Installed is not labelled API Ready on Connections; use actual Ready state and visible publication failures.
- F4/C3,C4: strengthen harness assertions (response model, per-cycle upstream calls, removed-route status/body, real unload before config removal). Startup-race smoke remains nondeterministic scheduling-wise; deterministic engine Go regression is the primary red/green proof.

No final PASS claimed. On final review the reviewer found two remaining R5 test-isolation leaks: a post-stop `ModelSourcesStore.shared` access could migrate live sources, and teardown reloaded the real registry after dropping the temp override (possibly scheduling live metadata writes). Both returned to the builder within the ongoing first repair round. A cancellation-before-first-write regression was also added with a controlled mutation red→green check; the builder is repeating final gates after the last edits. Earlier REVIEW hashes are retained as intermediate snapshots, not the final code fingerprint.

## LOOP

- Repairs: 2 (maximum 3 cumulative).
- Current phase: COMPLETE / SPECLOOP PASS. Independent reviewer isolation preserved: reviewer changed only its own review artifact, not production/builders' specs or tests. All required C1–C5 gates PASS on the final frozen fingerprints; native Windows runtime remains unexecuted and installed/release distributions remain unchanged.
- User explicitly authorized preserving both lanes and fixing compatibility on 2026-11-06. Independent review found: identical-YAML idempotency suppressed required publication retry rewrites on both platforms; macOS unreadable-source guard returned success instead of throwing. Repair 2 is restricted to an explicit force-write path for local publication (normal idempotency/debounce retained), a visible thrown source-load error, production-writer regression tests for identical add/remove retry writes, and fresh final C1–C5 evidence. A concurrent Windows rename-failure fallback used in-place truncating writes; retain bounded rename retry but fail visibly without truncating the existing config. Earlier fingerprints/counts below are historical, not the repaired final tree.
- Per-finding attempts: F1–F4 each one repair attempt. Platform final gates recorded above; no final PASS until independent review.
- REVIEW snapshot fingerprints (SHA-256 of raw tracked `git diff`, including baseline dirty changes): root `a2a3b652946ce210482387a5f57a1b9ee4258755e875a3d703ab772cc9973c5e`; MacOS `cf3bdfd91d158b6bebda5b44dc812e5d197335797df3ea3ce6459b512a6de65c`; Windows `8a0c0b927c902ab669841a7d0bf3d37809051c34722ad28cb6e0a428e1f157c9`; engine `2894664549607550c4496cdc14fc4725580a72bd60328b9b8d83d7e5cee5e431`.
- Relevant untracked artifacts (SHA-256): engine patch `eae497f2844a34375aa1bfbdb14251368f24fab1b6a885a1e17af36af9460480`; `scripts/test_local_ai_gateway.py` `e063d7b963903c7df774930a6178d46870f47197ecc526f8c22d067e832fc518`; `scripts/test_local_ai_runtime_gateway.py` `42824edffdcb2a1e4f3e3b35349713d9cd81514f3ae40c0d207f49062509b768`; Chrome harness `1587660529f0a62f99c110289aa723e84b18c592528f014623c43e58030c026c`; Connections JS harness `b5971ecf22bdbf00b8146a78be51d2ab13916b9c8a2dc27f119ab0a70228940a`; macOS fixture `107b3bfadc261e5bfcb07e42b53ee1d1a81deca8d15ccc3aad19a53fed13abd0`; Windows fixture `686a2f7b92c7eec9bd18d34f8c8b3d46218f4b42a0461236fc358f2faff20deb`.
