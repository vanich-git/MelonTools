# Melon Tools 2.3.7

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

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.3.7.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.3.7-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.3.7-win-x64-portable.exe) — single file, no install.

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
