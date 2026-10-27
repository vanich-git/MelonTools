# Melon Tools 2.4.2

Official OpenAI model refresh, plus the 2.4.1 reliability and security fixes.

- **Load models now asks OpenAI.** The Codex account editor calls
  `https://chatgpt.com/backend-api/codex/models` with the selected account's
  access token, merges the official `models` array into
  `~/.codex/models_cache.json`, and regenerates the Codex catalog. Models such
  as `gpt-6.1-terra` appear without waiting for the Codex app cache to refresh.
- **Safe cache merge.** Codex-owned metadata (`identity`, `etag`) is preserved;
  only the model list, fetch timestamp and client version are replaced. The
  cache is written atomically with restrictive permissions.
- **Both platforms.** macOS uses `CodexService` / `CodexPoolModelsStore`; Windows
  uses the `codex_models_refresh` command and the same endpoint/merge logic.
- **Token handling.** A 401 rotates the access token once and retries; refreshed
  tokens are persisted on Windows and reused by the normal quota path.
- **Fallback unchanged.** If OpenAI is unreachable, the local cache and bundled
  catalog still populate the picker and the error is shown in the editor.
- **Includes 2.4.1.** Adaptive live quota, incremental rollout reads, compressed
  macOS engine, scheduler summaries, schema guards, stricter backup KDF, CSP
  bridge and the other audit fixes.

### Upgrading from 2.4.1

Open **Accounts → Codex account → Load models**. The app fetches the official
list, shows the new model, and writes it to the Codex catalog. Relaunch the
Codex app to refresh its picker.

## 2.4.1

Audit fixes for macOS and Windows: lower background load, safer persistence,
a smaller macOS app, and a reproducible Windows engine.

- **Quota guard without the 1.5-second churn.** Live quota is adaptive,
  diff-based, persists at most every 30–45 s, reuses one HTTP client and takes
  one vault snapshot per tick. It stops when the gateway is not running.
- **Incremental rollout reads.** The macOS composer parses only appended
  rollout lines instead of re-reading up to 32 MB every 5 s.
- **Smaller macOS app.** The universal gateway is embedded gzip-compressed
  (~45 MB vs ~139 MB), extracted into Application Support and SHA-256 checked
  before launch. The installed app is about 63 MB instead of ~156 MB.
- **Scheduler payloads.** Windows dashboard polls a compact summary; history is
  paged without result bodies and full results load on demand. macOS deferred
  heavy startup work until after the first frame.
- **Security.** Windows backup import validates account ids; the UI has no
  inline handlers, uses a command-whitelisted Tauri bridge and a strict CSP;
  backup format v2 uses PBKDF2 600k with header-bound AES-GCM AAD; instance
  `auth.json` writes are atomic 0600; CDP port ownership is verified.
- **Schema safety.** Vault/settings/scheduler stores carry `schemaVersion`;
  files from a newer build open read-only instead of losing fields.
- **Windows engine reproducibility.** The embedded CLIProxyAPI blob was rebuilt
  from pin `1f917e77` with Go 1.26.10; compressed and payload hashes match the
  provenance file and CI reproduces them.
- **Release hygiene.** Draft releases, pinned XcodeGen/NSIS, checksum/manifest
  verification, SBOM/provenance, CodeQL Swift, clippy `-D warnings`, and a
  support-bundle export on both platforms.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v2.4.1/MelonTools-2.4.1.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v2.4.1/MelonTools-2.4.1-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v2.4.1/MelonTools-2.4.1-win-x64-portable.exe) — single file, no install.

## 2.4.0

- **Per-account Codex models.** Every Codex account has its own model
  checkboxes. The app keeps one common pool of selected models, so a model
  enabled anywhere stays available to the gateway. Hidden and internal routes
  are never offered as choices and are preserved.
- **`excluded_models` in auth files.** Each account's choice is written as
  `excluded_models` in its Codex auth file. The gateway then routes a model
  only to accounts that allow it, instead of sending every model to every
  account.
- **Predictable picker.** The Codex picker reflects the selection after a
  relaunch of the Codex app; the accounts page states this explicitly.
- **macOS and Windows parity.** Both platforms read and write the same
  per-account filters and produce the same pool of selected models.
- **Build metadata.** macOS build 25; version metadata is aligned at 2.4.0 on
  macOS and Windows.
- **Release checksums.** Checksums are regenerated from the 2.4.0 artifacts;
  earlier sums no longer apply.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v2.4.0/MelonTools-2.4.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v2.4.0/MelonTools-2.4.0-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v2.4.0/MelonTools-2.4.0-win-x64-portable.exe) — single file, no install.

## 2.3.7

- **Windows routing order fixed.** The first account in the planner now gets
  the highest gateway priority, matching macOS and CLIProxyAPI `fill-first`.
  Preferred, custom and quota-high order are no longer inverted.
- **Gateway security update.** CLIProxyAPI v8.0.44 with Go 1.26.10, `x/net`
  0.60.0, `x/crypto` 0.57.0, `go-git` alpha.5, `x/text` 0.42.0 and
  `klauspost/compress` 1.18.7. `govulncheck` reports 0 reachable
  vulnerabilities.
- **Updater hardening.** Windows download URLs are parsed with the same URL
  parser as the HTTP client. Backslash, userinfo and non-standard port tricks
  can no longer bypass the host allowlist.
- **Parity fixes.** macOS and Windows use the same plan-rank table, and auth
  files without an email get a stable name that does not depend on order.
- **Build metadata.** macOS build 24; version metadata is aligned at 2.3.7.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v2.3.7/MelonTools-2.3.7.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v2.3.7/MelonTools-2.3.7-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v2.3.7/MelonTools-2.3.7-win-x64-portable.exe) — single file, no install.

## 2.3.6

- **Exact quota reserve on macOS and Windows.** Live Codex quota signals are
  checked about every 1.5 seconds. Routing pauses exactly at the configured
  threshold, persists the block, and resumes after fresh recovery or a
  confirmed window reset. The UI shows the actual stop value.
- **Reliable quota synchronization.** Auth-file sync writes only changes;
  quota/history persistence is batched, 401 quota requests retry once, and
  reset probes use backoff.
- **Responsive Windows onboarding.** The welcome dialog appears before slower
  startup checks, uses a native modal layer, keeps its actions clickable, and
  pins the action row while the content scrolls.
- **Build metadata.** macOS build 23; version metadata is aligned at 2.3.6.

## 2.3.5

- **DeepInfra and Vercel AI Gateway.** Connect with provider API keys and load
  chat models from DeepInfra or language models from Vercel AI Gateway.
- **Connections UI.** Provider cards use a full-width vertical layout on macOS
  and Windows. DeepInfra shows model count and session spend; Vercel shows team
  balance, lifetime spend and models.
- **OpenRouter balances.** The available balance is shown without a progress bar.
  The remaining key limit keeps its own gauge, and lifetime spend remains separate.
- **Build metadata.** macOS build 22; version metadata is aligned at 2.3.5 on
  macOS and Windows.

## 2.3.1

- **Automatic recovery after capacity errors.** Codex's native Retry is pressed
  automatically while it is offered. When Codex stops offering Retry, Melon
  Tools sends a short continuation so a long task keeps moving without a manual
  click.
- **Quota-aware guard.** The watcher stays silent when every account is paused
  or the best 5-hour quota is at or below 5%. A model that is unavailable
  because of limits no longer produces a stream of continuation messages.
- **Visible control.** «Продолжать автоматически после перегрузки модели» is
  available in Settings → Codex and on the Codex → Composer chips page.
- **Build metadata.** macOS build 21; version metadata is aligned at 2.3.1 on
  macOS and Windows.

## 2.3.0

- **Workspace-aware scheduler.** Tasks can use a working directory and append
  bounded `git status`, recent log and diff stat to the prompt. Optional
  `max_tokens` caps each completion.
- **Guardrails.** Scheduled runs pause when the Codex pool has no usable
  account, and an optional daily token limit skips a task before any request
  when today's budget is spent. Provider-namespaced models stay independent.
- **Queue, cancel and retries.** `Run now` while busy is queued visibly; the
  active request can be cancelled; failures retry with a bounded delay and
  resume the normal schedule afterwards.
- **Encrypted backup / export / import.** One portable AES-256-GCM backup
  (PBKDF2-HMAC-SHA256, 210,000 rounds) covers scheduler tasks and history,
  settings, accounts and auth files, and model sources. Logs and gateway keys
  are excluded. Restore validates and decrypts before replacing live data.
- **Onboarding 2.0.** A live health check covers the gateway, accounts, model
  catalog, scheduler and last backup. Each failed row links to the relevant
  screen, and a disabled demo task can be created without sending a request.
- **Release hygiene.** Version metadata is aligned at 2.3.0 on macOS and
  Windows. Builds remain ad-hoc signed on macOS and unsigned on Windows.

## Earlier fixes

- **2.2.4:** Full audit remediation: security and data handling, updater
  hardening, scheduler corruption handling, logs/CDP/quota protections, Windows
  Rust quota loop, equal dashboard tiles, provider-aware composer, Antigravity
  verification diagnostics.
- **2.2.3:** Equal dashboard tiles, provider-aware composer, Antigravity
  verification diagnostics.
- **2.2.2:** macOS refreshes the Codex model catalog on launch.
- **2.2.1:** Shared models stay visible under every provider.
- **2.2.0:** Cron schedules, task templates, menu-bar/tray background execution.
- **2.1.1:** Google Antigravity sign-in callback on port 51121.
- **2.1.0:** Dashboard 2.0, menu-bar/tray actions, task/reset notifications.
- **2.0.3:** Portable asset naming and legacy updater alias.
