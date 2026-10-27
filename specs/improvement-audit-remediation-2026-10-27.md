# Audit remediation status — 2.4.1 worktree

Source audit: `specs/improvement-audit-2026-10-27.md`.
Worktree: APFS worktree `audit-fixes-2.4.1`; no commits or pushes.

## Closed

| ID | Change |
|----|--------|
| M1 | Delayed vault save resets `saveTask` with a generation guard, so later saves are not stuck. |
| M2 | Live quota is adaptive (1.5 s only while serving/near a reserve), diff-based, persists at most every 30 s, and App Nap is held only while active. |
| M3 | Exact-thread rollout reads are incremental by byte offset and size/mtime; only appended lines are parsed, idle reads are cached for 10 s, and an `OSSignposter` interval plus debug timing is emitted. |
| M4 | `ModelSourcesStore` builds a lowercased alias/id/display index invalidated by `sources.didSet`; `priceRow` is O(1) after the pool check. |
| M5 | Debug/test host uses `dev.melontools.app.debug`; Release keeps `dev.melontools.app`. Tests pass while the installed app is running. |
| M7 | Startup loads vault/catalog/composer after the first runloop turn, with `Startup`, `CatalogSync`, `ComposerStart` and `GatewayStart` signpost intervals. |
| M8 | Semantic fonts in the shared theme/components and scheduler view, plus `@ScaledMetric` for metric values and empty-state icons. |
| M9 | `MacOS/scripts/l10n_lint.py` rejects duplicate and missing keys; run in CI. |
| W1 | One gateway client, one vault snapshot per tick with a write-invalidated accounts cache, batched quota writes every 45 s, immediate write on block transitions, and the loop stops when the engine is down. |
| W2 | Added `scheduler_summary`, paged `scheduler_history(page, limit)` without result bodies, and `scheduler_result(id)`; dashboard polls the summary only. |
| W3 | Backup import rejects unsafe/duplicate account ids; UI has no inline handlers and escapes ids through `data-*`; static regression test covers a hostile id. |
| W4 | `render()` performs no IPC; loads happen on boot/navigation/explicit actions. |
| W5 | Status polling uses `Promise.allSettled` + per-command timeout, records `lastError`, shows a stale/error footer, and backs off. |
| W7 | Tray labels follow `settings.lang` and are rebuilt when the language changes. |
| W8 | Antigravity polling is gated on the connected state and backs off exponentially. |
| W9 | `withGlobalTauri: false`, `script-src 'self'`, and a whitelisted `window.melon` bridge. |
| R2 | README uses stable unversioned aliases; release notes use versioned release URLs. |
| R4 | Test-count claim removed from the local agent note. |
| R6 | `build.sh` signs the embedded engine explicitly, then the app; no `codesign --deep` signing. |
| R9 | Corrupt-vault quarantine keeps the newest three files and drops entries older than 30 days. |
| R10 | Backup format v2: PBKDF2 600k, AES-GCM AAD over the header; v1 backups still import on both platforms. |
| R11 | Instance `auth.json` uses `SecureFile.write` (0600 atomic) and a 0700 directory. |
| R12 | CDP injection verifies the listener PID owns the port before connecting; mismatch refuses the session. |
| R13 | Quit helper receives the app path as `$1` and quotes it. |
| REL-1 | `scripts/verify_release_checksums.py` checks Cask/winget against artifacts/SHA256SUMS; CI and release workflow call it. |
| REL-3 | `MelonTools.entitlements` with Apple Events automation; wired into `project.yml` and both signing scripts. |
| REL-4 | Release runs `xcodegen generate`; CI has non-publishing macOS and Windows package jobs. |
| REL-5 | `environment: release`, signing secrets scoped to steps, notary profile instead of repeated argv, Windows cert store instead of `/p`. |
| REL-6 | Releases are drafts, `make_latest: false`, published assets cannot be replaced by a rebuild, and the body includes `SHA256SUMS`. |
| REL-9 | `docs_lint` validates `tauri.conf.json`, `Cargo.lock`, `Info.plist`, release notes, versioned links and manifest checksums. |
| REL-10 | Stable aliases published; README links updated; `links.yml` runs the HTTP link checker. |
| REL-11 | NSIS supports English + Russian, remembers the installer language, and is documented as the only Windows installer path. |
| REL-12 | `schemaVersion` in vault/settings/scheduler on both platforms; newer files are read-only and refuse writes; uninstall restores the Codex route; NSIS refuses downgrades. |
| REL-13 | CI runs `node --check` on UI/composer scripts, UI static checks, `bash -n`, actionlint, and `cargo fmt --check`. |
| REL-14 | `.gitattributes`, secret ignore rules, and read-only `scripts/doctor.sh`. |
| REL-15 | Docs corrected for Go 1.26.10, universal build, engine sizes, NSIS path, and storage locations. |
| R7 | Removed the unused `schedulerAt`; page timers are scoped to their page and `_renderResumeTimer` is cleared on resume. |
| M6 | macOS ships a gzip-compressed universal engine (~45 MB vs ~139 MB). The Release app is ~63 MB instead of ~156 MB; the engine is extracted into Application Support, verified by SHA-256 before every launch, and repaired if tampered. |
| W2 | Scheduler page loads `scheduler_tasks` plus paged `scheduler_history`; result bodies are fetched per entry. Full `scheduler_list` is only a compatibility fallback / save response. |
| W6 | `app.js` split from 4,890 to 1,090 lines; actions moved to `mt-actions.js`, pages to `mt-pages.js`, plus state/api/i18n/utils/bridge modules. |
| R3 | The visible 1.4.1 footer was cropped from the README screenshot. |
| R8 | Redacted support bundle on macOS (save JSON) and Windows (copy JSON); no secrets or auth bodies. |
| REL-2 | Rebuilt the Windows engine from the pinned commit; SHA-256 matches exactly; CI reproduces and compares it. |
| REL-7 | XcodeGen pinned to 2.46.0 with archive SHA-256; NSIS pinned to 3.11; Go/Node/PyYAML already pinned. |
| R5 | `cargo clippy -- -D warnings` is clean and gated in CI; clippy/rustfmt components are installed explicitly. |

## Partial / not closed

| ID | Remaining work |
|----|----------------|
| REL-5 | GitHub environment/branch/tag protection must be configured in repository settings; not possible from the repo. |
| X2 | One canonical `shared/composer-chips.js` (sync check in CI) plus shared quota and routing fixtures consumed by Swift and Rust; catalog/cron/composer-payload fixtures remain. |
| REL-8 | SBOM, provenance attestation, govulncheck, CodeQL JavaScript and CodeQL Swift are wired. Go CodeQL is not wired because the engine source is fetched outside the git tree; Rust has no CodeQL extractor. |
| Signing | Notarization/Authenticode remain blocked on certificates. |
| Runtime | Windows tray/toast/uninstaller/updater behavior needs a Windows VM. |

## Verification run

- `xcodebuild ... test` with the installed app running: **TEST SUCCEEDED**.
- `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo check --locked`, `cargo test --locked`: **186 passed**.
- `node --check` for every UI/composer script, plus `Windows/app/tools/ui-static-check.js`: OK.
- `python3 MacOS/scripts/l10n_lint.py`: 709 keys / 680 call sites, OK.
- `python3 .github/scripts/docs_lint.py`: OK (4 workflows, 3 winget manifests).
- `python3 scripts/verify_release_checksums.py --warn-on-hash-drift`: OK.
- `python3 Windows/scripts/verify-engine.py`: OK.
- `actionlint`, `bash -n`, `scripts/doctor.sh`: OK.
- Browser demo smoke test: onboarding, dashboard, scheduler, providers, accounts, and delegated navigation with no console errors.
- `MacOS/build.sh`: unsigned Release app + DMG built (52 MB DMG, 63 MB installed app) with the compressed engine embedded.
