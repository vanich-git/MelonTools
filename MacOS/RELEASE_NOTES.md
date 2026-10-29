# Melon Tools 3.2.0

Update notifications on macOS and Windows.

- **The sidebar button becomes «Обновить».** When a newer release is found,
  «Проверить обновление» changes to a gold **Обновить** button on both
  platforms.
- **Visible notice.** macOS shows a banner in the sidebar with the new version;
  Windows shows an in-app toast once per version.
- **Hourly check.** Both apps check while running (at most once per hour) and on
  launch, so a new release is noticed without reopening the app.
- **Includes 3.1.2.** Every account is listed in the API control card, quota
  limits use live pool totals, and the Codex config/chips fixes are present.
- **Build metadata.** macOS build 35; version metadata is aligned at 3.2.0.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v3.2.0/MelonTools-3.2.0.dmg)
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v3.2.0/MelonTools-3.2.0-setup.exe)
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v3.2.0/MelonTools-3.2.0-win-x64-portable.exe)

### SHA-256

```
a7d37162917002748ece36b61d54c3fb8bc5e9a78c9ed35f33130405f1f1d214  MelonTools-3.2.0.dmg
6ce9298b8a22da4a23a06cc4b8aae80850d2e8a6c9a33b477ad46a035dafbe13  MelonTools-3.2.0-setup.exe
d5fc4b83beb2b8cfe080b9b15460ecf5a883d36f1cff23ab38233706bb7ce299  MelonTools-3.2.0-win-x64-portable.exe
d5fc4b83beb2b8cfe080b9b15460ecf5a883d36f1cff23ab38233706bb7ce299  MelonTools-3.2.0-win-x64.exe
```

## 3.1.2

Account list fix in the API control card.

- **macOS shows every account.** The API control card on the Accounts page no
  longer truncates the routing preview to three rows with “+N more”. All pool
  accounts are listed when the card has room.
- **Windows already lists all accounts.** The same card is verified to keep the
  full order without a hidden limit.
- **Includes 3.1.1.** Лимиты квот use live pool totals on both platforms.
- **Build metadata.** macOS build 34; version metadata is aligned at 3.1.2.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.2/MelonTools-3.1.2.dmg)
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.2/MelonTools-3.1.2-setup.exe)
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.2/MelonTools-3.1.2-win-x64-portable.exe)

### SHA-256

```
15be71003e14fad6da75c8bf106dc0f0544603ed996f252593b8da7a44a271d4  MelonTools-3.1.2.dmg
9f4caef93c2793408c21b7227030151894fc10dcad59353979512a77882db152  MelonTools-3.1.2-setup.exe
6f7eff44f732883b9b59ea8114fa252fd50d850ab6d5fad078c74310f9cf967f  MelonTools-3.1.2-win-x64-portable.exe
6f7eff44f732883b9b59ea8114fa252fd50d850ab6d5fad078c74310f9cf967f  MelonTools-3.1.2-win-x64.exe
```

## 3.1.1

Quota-limit totals on macOS and Windows.

- **Лимиты квот use the current pool.** The dashboard card now sums the live
  account quotas instead of historical samples or averages. Two accounts at
  100% and 4% read 104% of 200%; five accounts at 100% read 500% of 500%.
- **macOS parity.** The macOS card no longer shows history sparklines/averages;
  it uses the same total formula and account-quota bars as Windows.
- **Consistent with account cards.** The value and bar are derived from the same
  `hourlyRemaining`/`weeklyRemaining` fields shown on each account card.
- **Build metadata.** macOS build 33; version metadata is aligned at 3.1.1.
- Includes the 3.1.0 Codex `config.toml` and Windows composer-chips fixes.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.1/MelonTools-3.1.1.dmg)
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.1/MelonTools-3.1.1-setup.exe)
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.1/MelonTools-3.1.1-win-x64-portable.exe)

### SHA-256

```
bd9102633b242adf5a76c5bfbd3d377267e77aef9c7d426f1203e72de4df6d8d  MelonTools-3.1.1.dmg
7cce97b22aa553494d27ce1629b36029822895d9258e662461ecc4e074655758  MelonTools-3.1.1-setup.exe
3748c0e67762ef9a09a946f2dd80f9f26b981fdf4c6dd86b68ee312b94d2686a  MelonTools-3.1.1-win-x64-portable.exe
3748c0e67762ef9a09a946f2dd80f9f26b981fdf4c6dd86b68ee312b94d2686a  MelonTools-3.1.1-win-x64.exe
```

## 3.1.0

Codex route compatibility and Windows composer chips.

- **`config.toml` keeps third-party providers.** Applying the Melon route now
  preserves every existing `[model_providers.*]` table. Removing the route no
  longer restores an old whole-file backup; only Melon's own top-level keys and
  provider blocks are touched.
- **Legacy provider alias.** Melon creates/refreshes
  `[model_providers.codex_local_access]` with the current gateway URL and token.
  Older chats that saved this provider id no longer fail with
  `Model provider not found`.
- **Windows composer chips.** The bridge now recognises both `ChatGPT.exe` and
  `Codex.exe`, remembers the debug port chosen by Melon at launch, and keeps it
  while Codex starts. Chips attach after **Launch Codex** or **Relaunch Codex
  with chips**.
- **Includes 3.0.1.** Dark custom fields, the account settings dialog and the
  **Лимиты квот** label.
- **Build metadata.** macOS build 32; version metadata is aligned at 3.1.0 on
  macOS and Windows.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.0/MelonTools-3.1.0.dmg)
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.0/MelonTools-3.1.0-setup.exe)
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v3.1.0/MelonTools-3.1.0-win-x64-portable.exe)

### SHA-256

```
d992bfc4963c78607d73055a065f0556c6e971505dc1f7724fa0ac0af1ad0a2b  MelonTools-3.1.0.dmg
8c1d71c50ef65c78f97bf4f77acd8329bf044bdca2d8934db185bc64386ad4f1  MelonTools-3.1.0-setup.exe
7222808a57b0c400f9df1810487e80949d793f8bcd2adda0e3d346e940d863fe  MelonTools-3.1.0-win-x64-portable.exe
7222808a57b0c400f9df1810487e80949d793f8bcd2adda0e3d346e940d863fe  MelonTools-3.1.0-win-x64.exe
```

## 3.0.1

UI polish for the Windows 3.0 release.

- **Custom fields everywhere.** Text, number, password, select, file and
  checkbox controls now use the dark Melon Tools style instead of native white
  inputs. Number spinners and the system select arrow are replaced.
- **Account settings button.** Each Codex account card has the macOS-style
  sliders button. Reserve limits, “always first” and “backup” moved into an
  **Account settings** dialog instead of cluttering the card.
- **Quota limits label.** The dashboard card is now **Лимиты квот** (Quota
  limits) instead of “Тренды квот”.
- **Build metadata.** macOS build 31; version metadata is aligned at 3.0.1 on
  macOS and Windows.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v3.0.1/MelonTools-3.0.1.dmg)
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v3.0.1/MelonTools-3.0.1-setup.exe)
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v3.0.1/MelonTools-3.0.1-win-x64-portable.exe)

### SHA-256

```
1798e5f26bf0ac8f205853cff2c81d519fd25d1c4b949cb4775260d0a147d07b  MelonTools-3.0.1.dmg
1c5c9d9679c09cceaaddacd244b67737d9613cf7017564faab3ef3a50c25e0ab  MelonTools-3.0.1-setup.exe
fe331acadb2f437f3902d6f2011deba66445b7902c36c91a826858ae0f9a47f5  MelonTools-3.0.1-win-x64-portable.exe
fe331acadb2f437f3902d6f2011deba66445b7902c36c91a826858ae0f9a47f5  MelonTools-3.0.1-win-x64.exe
```

## 3.0.0

Windows UI parity with macOS. Both platforms share the 3.0.0 version and the
2.4.4 feature set; macOS is functionally unchanged.

- **macOS-style Windows interface.** The Windows build now has the same
  sidebar-card navigation, bento cards, Segoe UI Variable typography, capsule
  buttons, switches and compact headers as the macOS app. The window uses the
  native Windows title bar with standard minimize/maximize/close buttons on the
  right.
- **Dashboard.** Six aligned cards cover pool health, scheduler, quota trends,
  spend, the Codex pool and the API service. Quota trends show the **total**
  remaining quota of the account pool: five accounts at 100% read 500%, not a
  100% average. Bars use the same style as account quotas.
- **Launch Codex from the app.** The API page has a single **Launch Codex**
  action. Melon Tools starts the service, applies the Codex route and opens the
  desktop app with the composer-chips debug port. If `ChatGPT.exe` is not found,
  a clear dialog offers **Choose ChatGPT.exe**, **Download Codex** and **Retry**.
  A manually selected path is stored in `settings.json` (`codexExePath`);
  `MELON_CODEX_EXE` is now only a hidden fallback.
- **Accounts.** The API control card matches the account cards in height, the
  current account is marked, and bulk JSON import is preserved from 2.4.3.
- **Settings.** Appearance, language and accent, dashboard widgets, service,
  notifications, backup and About are grouped like macOS. The Network / Proxy
  section from 2.4.4 is kept.
- **Complete RU/EN strings.** New labels and launch dialogs are translated.
- **Reliability.** Includes the 2.4.1 security/audit fixes, the 2.4.2 official
  model catalog refresh, 2.4.3 bulk import, and the 2.4.4 proxy and tray-menu
  fixes.
- **Build metadata.** macOS build 30; version metadata is aligned at 3.0.0 on
  macOS and Windows.
- **Release checksums.** Checksums below are generated from the 3.0.0
  artifacts; earlier sums do not apply.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows) because certificate/notarization secrets are not configured.
> Verify every download against its `.sha256` file or the combined
> `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/download/v3.0.0/MelonTools-3.0.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/download/v3.0.0/MelonTools-3.0.0-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/download/v3.0.0/MelonTools-3.0.0-win-x64-portable.exe) — single file, no install.

### SHA-256

```
f5f0620f8085898daaf959bbc267fe4a1abd6836c2a546099a1d13ead09c07ea  MelonTools-3.0.0.dmg
1f904a7070aad48f7d397f63260fee3838b66ca16cb0cebd963841ace227d486  MelonTools-3.0.0-setup.exe
79612d964c3ab3cd955937aaab2185f8f07c77492c3c87384b6ee53a49dcca92  MelonTools-3.0.0-win-x64-portable.exe
79612d964c3ab3cd955937aaab2185f8f07c77492c3c87384b6ee53a49dcca92  MelonTools-3.0.0-win-x64.exe
```

## 2.4.4

Network / Proxy support for macOS and Windows.

- **Network / Proxy settings.** A new settings section adds an enable switch, a
  Proxy URL field and a bypass list (default `127.0.0.1,localhost`).
- **System proxy fallback.** Leave the URL empty while the switch is on to use
  the macOS system proxy or the Windows per-user Internet Settings proxy. On
  macOS the proxy is resolved with `CFNetworkCopyProxiesForURL` for the target
  host, so PAC scripts and auto-discovery work too. A running gateway rewrites
  `config.yaml` when the system proxy changes, without an app restart.
- **Gateway proxy.** The generated `config.yaml` now contains:
  `requests.proxy-url`, so OpenAI, Codex and provider upstream traffic from the
  embedded CLIProxyAPI engine goes through the proxy. The setting survives app
  restarts and gateway rebuilds.
- **Application proxy.** Quota, official model catalog, provider model lists and
  update checks use `URLSessionConfiguration.connectionProxyDictionary` on
  macOS and `reqwest::Proxy` on Windows.
- **Local traffic stays direct.** Gateway management, health, CDP and scheduler
  loopback calls explicitly bypass the proxy, so `127.0.0.1:18317` never goes
  through the tunnel.
- **Windows tray menu.** Right-click on the tray icon now reliably opens the
  menu. Before, the click handler focused the main window and the popup was
  dismissed as it appeared. Left click still opens the window.
- **Fixes the region error.** A system proxy now applies to the engine instead
  of only the WebView/app layer, avoiding
  `unsupported_country_region_territory` from OpenAI when the direct route is
  blocked.
- **Includes 2.4.3.** Bulk Cockpit/CPA and sub2api JSON import, plus the 2.4.2
  official model refresh and earlier reliability/security fixes.

### Upgrading from 2.4.3

Open **Settings → Network / Proxy**, enable the switch, and either paste a
proxy URL (`http://`, `https://`, `socks5://`, `socks5h://`) or leave it empty
to use the system proxy. Keep `127.0.0.1,localhost` in the bypass list. macOS
applies changes immediately after you edit a field; on Windows press **Apply**.

## 2.4.3

Bulk account import for macOS and Windows.

- **Import JSON button.** The Accounts page now has a separate **Import JSON**
  file picker. It accepts both common pool-export formats instead of requiring
  a browser login for every account.
- **Cockpit / CPA.** A flat JSON array with `email`, `account_id`,
  `access_token`, `refresh_token` and `id_token`.
- **sub2api-data.** `type: "sub2api-data"` with `accounts[].credentials`;
  OpenAI/OAuth entries are imported and other platforms are skipped.
- **Refresh tokens are preserved.** Imported accounts keep `refresh_token` and
  `chatgpt_account_id`, so the existing quota/refresh scheduler can renew
  `access_token` in the background. Emails, plan and account ids are also read
  from the `id_token` when present.
- **Safe merge.** Accounts are merged by ChatGPT account id or email. Re-import
  updates tokens and profile data without duplicating the pool; local routing
  preferences and quota cache stay intact. Duplicates inside one file are
  skipped.
- **Storage.** macOS writes through `SecureFile` (0600); Windows stores tokens
  with the existing DPAPI protection.
- **Includes 2.4.2.** Official OpenAI model refresh (`Load models` calls
  `chatgpt.com/backend-api/codex/models`), plus the 2.4.1 reliability and
  security fixes.

### Upgrading from 2.4.2

Open **Accounts → Import JSON**, choose a Cockpit/CPA or sub2api-data export,
review the summary, then use the normal account/model controls.

## 2.4.2

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
