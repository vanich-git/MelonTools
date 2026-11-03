# Melon Tools

A native macOS cockpit for the **Codex account pool**, model providers and **scheduled model tasks**.
Built with SwiftUI, macOS 14+, universal (Apple Silicon + Intel).

```
┌─────────────────────────────────────────────────────────────┐
│  Melon Tools                                                │
│                                                             │
│  Codex            Scheduler            App                  │
│  ├─ Accounts      ├─ Tasks             └─ Settings          │
│  ├─ API Service   ├─ Run now                                │
│  ├─ Connections   ├─ History                                │
│  ├─ Composer      └─ Results                                │
│  └─ Instances                                               │
└─────────────────────────────────────────────────────────────┘
```

## What's new in 5.5.5

- **Status island.** A borderless panel at the top of the screen follows the
  camera cut-out. It rests as a compact pill or as one continuous black bar
  with hourly and weekly totals beside the cut-out, and opens on hover into a
  status card with the pool, Antigravity, providers, the scheduler and
  Open / Pause API / Run.
- **Correctness.** The side-by-side layout keeps its height on displays without
  a notch, the island follows language changes, "Open" unminimises the main
  window, and Start/Run have distinct Russian labels.
- **Less work in the background.** Pointer tracking is throttled to 30 Hz and
  stops when the island is hidden; the view redraws only when a visible value
  changes.
- **Build metadata.** macOS build 52; version metadata is aligned at 5.5.5.

## Earlier: 5.0.1


- **Antigravity controls on Windows work again.** The bridge whitelist rejected
  pause, resume, priority, remove and probe; the command is allowed again.
- **The quota guard backs off.** A blocked account is polled every 1.5 s only
  while its window resets within five minutes; otherwise every 15 s. That
  removes ~40 management requests a minute and ~30 MB of gateway log per day.
- **A compact Antigravity card.** The "in the catalog, unavailable" list is
  collapsed behind a row with a count; expanding it shows a bounded grid.
- **Diagnostics.** Lifecycle, gateway and updater events go to the unified log.
- **Build metadata.** macOS build 51; version metadata is aligned at 5.0.1.

## What's new in 5.0.0

- **Flat dark canvas.** One `#111113` surface behind the sidebar and the board;
  cards are `#1F1F22` plates with an 18 pt radius and a neutral hairline. The
  coloured frames, radial glows, drop shadows and per-card backdrop blurs are
  gone, which also removed the per-frame rasterisation that made long boards
  stutter while scrolling.
- **Floating sidebar.** Navigation sits on its own plate with a per-section
  accent: the selected row takes a soft tint of that accent, a matching glyph
  and a trailing dot; hover stays a neutral `white 6%` wash.
- **Bento dashboard.** Two equal columns whose cards stretch to the row height,
  plus new **Providers** and **Account pools** cards.
- **Pool totals, not averages.** "Codex pool health" sums the remaining quota
  across the pool: five accounts at 100% read **500% of 500%**.
- **Status bar panel.** The menu extra drops the account list, uses SF Pro and
  shows pool totals and a single gateway status line.
- **Windows parity.** The Tauri shell ships the same palette, radii, plates and
  summary maths; only the system font differs.
- **New identity.** The amber melon-slice icon and the transparent logo.
- **Build metadata.** macOS build 50; version metadata is aligned at 5.0.0.

## What's new in 4.0.1

- **Probe releases every cooldown.** The watchdog is keyed by auth/model, so one
  timeout can quarantine several models of the same account. A successful probe
  now clears all of them instead of only the first.
- **Idle pool polls less.** Quota refresh follows gateway load: 60 s while
  requests run, 15 min when the pool is idle.
- **Logs rotate in long sessions.** The health tick rotates `gateway.log` past
  32 MB while the pool is idle, so it no longer grows for weeks.
- **Quarantine reasons.** The account row distinguishes a first-token timeout,
  exhausted quota, Cloudflare challenge, sign-in failure and payment/plan
  problems.
- **Build metadata.** macOS build 41; version metadata is aligned at 4.0.1.

## What's new in 4.0.0

- **Multi-account Antigravity.** Connect several Google accounts and manage
  each one from the Providers card: per-account models, pause/resume, sign-in
  refresh and removal. The engine pools them automatically.
- **Quota per account.** The 5-hour Gemini and Claude/GPT windows come from
  `fetchAvailableModels` with reset times; the weekly window is not exposed and
  is not shown.
- **Catalog-only block.** Grey rows list catalog ids none of the connected
  accounts is entitled to.
- **Antigravity first-token failover.** Only Google/Antigravity streaming
  accounts. When the first payload misses `stream-bootstrap-timeout-seconds`
  (default 60, 0 disables), the engine retries on another Antigravity account
  before the client sees the stream, then applies the 60 s → 5 min → 30 min →
  2 h quarantine ladder. Codex, Claude and API-key providers are not affected.
  The card shows the latest TTFT or switch, and a probe button releases a
  recovered account.
- **Build metadata.** macOS build 40; version metadata is aligned at 4.0.0.

## What's new in 3.4.2

- **The full Antigravity catalog.** Gemini 3.8 Flash (Low), Gemini 3.8 Flash
  (Medium) and Gemini 2.5 Pro are entitled on the connected account but were
  missing from the engine catalog. The app now completes the catalog on disk
  and points `models.catalog` at it, so all three appear in the Codex picker.
- **Survives a config rewrite.** The completed catalog lives in
  `gateway/models.json`; `config.yaml` only references it. Restarts and settings
  saves no longer drop the models.
- **Self-healing.** The overlay follows the engine's three-hour refresh cadence,
  removes duplicate ids (the engine rejects a catalog with a duplicate) and
  retries after a failed fetch.
- **Build metadata.** macOS build 39; version metadata is aligned at 3.4.2.

## What's new in 3.4.1

- **Explicit proxy URL save.** A round gold check button appears as soon as the
  proxy URL differs from the saved value. Click it or press Return; a short
  “Saved” confirmation follows. Windows has the same control and toast.
- **Authenticated proxies work.** SOCKS5 and HTTP proxy credentials are passed
  to URLSession. The old build produced `NSURLErrorBadURL` («неверный URL») on
  every quota refresh when the proxy required a login.
- **Z.ai GLM Coding Plan.** Add the provider by API key on macOS and Windows;
  GLM-5.3 and GLM-5.3-Flash use the Coding endpoint and fall back to a built-in
  catalogue when `/models` is unavailable.

## What's new in 3.4.0

- **Reset credits are now redeemable from the account card.** When an account
  has banked resets, the counter becomes a gold button («1 сброс»). A
  confirmation dialog spends one credit and clears the current Codex usage
  limit. The nearest-expiring credit is redeemed first.
- **Windows gets the same control.** The Windows app adds the gold button,
  native confirmation, backend consume call and immediate quota refresh.
- **Clear outcomes.** Success, “nothing to reset”, “no credit” and
  “already redeemed” are reported in the message card, and the quota refreshes
  right after redemption.
- **Expiry stays visible.** The button tooltip still shows the nearest credit
  expiry so a banked reset is not lost.

## What's new in 3.3.0

- Codex keeps every third-party `[model_providers.*]` table and gains the
  `codex_local_access` alias, so old chats keep working.
- Single-instance is a named OS mutex; a stale `app.lock` no longer blocks
  startup, and a second launch focuses the tray window.
- Windows assigns `cliproxyapi.exe` to a kill-on-close Job Object, so the
  engine cannot survive Melon and hold port 18317.
- One JSON export now imports Codex, Claude and Antigravity accounts.
- Includes 3.2.0: gold **Обновить** button, update notice, hourly checks.

## What's new in 3.2.0

- The sidebar button changes from **Проверить обновление** to a gold
  **Обновить** when a new version exists.
- macOS shows a sidebar notice; Windows shows a toast.
- Both apps check hourly and on launch.

## What's new in 3.1.2

- The macOS **API control** card lists every account instead of showing
  “+N more”.
- Windows keeps the full routing list; both platforms show all pool accounts.
- Includes the 3.1.1 live quota totals.

## What's new in 3.1.1

- **Лимиты квот** now sum the live account quotas on macOS and Windows. They
  match the account cards and show the pool maximum (5 accounts = 500%).
- Includes the 3.1.0 Codex config and Windows chips fixes.
- macOS build 33.

## What's new in 3.1.0

- **Codex `config.toml` safety.** Third-party provider tables are preserved,
  and a legacy `codex_local_access` alias keeps old chats working.
- **Windows composer chips.** Both `ChatGPT.exe` and `Codex.exe` are supported;
  the launch debug port is remembered so chips attach reliably.
- Includes the 3.0.1 field and account-settings fixes.
- macOS build 32, version 3.1.0.

## What's new in 3.0.1

- **Custom fields.** Dark text, number, select and checkbox controls replace
  native white inputs, including the network/proxy card.
- **Account settings dialog.** The account card now has the macOS-style sliders
  button; reserve limits, “always first” and “backup” live in the dialog.
- **Лимиты квот.** The dashboard card was renamed from “Тренды квот”.
- **Build 31**, version 3.0.1 on macOS and Windows.

## What's new in 3.0.0

- **Windows parity release.** The Windows app now follows the macOS layout:
  sidebar card, grouped navigation, bento cards, Segoe UI Variable, capsule
  buttons and switches, and a native Windows title bar with right-side controls.
- **Codex launch flow.** The Windows API page starts the service, applies the
  route and opens Codex. A missing `ChatGPT.exe` now opens a clear picker dialog
  instead of a technical environment-variable error.
- **Pool quota totals.** Dashboard quota trends sum the current pool quota. The
  bars match the account quota style, and five accounts at 100% read 500%.
- **Version alignment.** macOS build 30 and Windows 3.0.0 share the 2.4.4
  feature set, including network/proxy support, bulk JSON import and the tray
  menu fix. The macOS app itself is functionally unchanged from 2.4.4.

## What's new in 2.4.0

- **Per-account Codex models.** Each Codex account has its own model
  checkboxes. Selections share one common pool, and hidden or internal routes
  stay preserved because they are never offered as choices.
- **`excluded_models` routing.** Account choices are written as
  `excluded_models` in the Codex auth files, so the gateway sends a model only
  to accounts that allow it.
- **Predictable picker.** The Codex picker shows the selection after the Codex
  app is relaunched.
- **macOS and Windows parity.** Both platforms apply the same per-account
  filters and build the same pool of selected models.
- **Build metadata.** macOS build 25; version metadata is aligned at 2.4.0 on
  macOS and Windows. Release checksums are regenerated from the 2.4.0
  artifacts.

## What's new in 2.3.7

- **Windows routing order fixed.** The first account in the planner now gets
  the highest gateway priority, matching macOS and CLIProxyAPI `fill-first`.
- **Gateway security update.** CLIProxyAPI v8.0.44 with Go 1.26.10, `x/net`
  0.60.0, `x/crypto` 0.57.0, `go-git` alpha.5, `x/text` 0.42.0 and
  `klauspost/compress` 1.18.7; `govulncheck` reports 0 reachable issues.
- **Updater hardening.** Windows download URLs use the same parser as the HTTP
  client, so backslash, userinfo and port tricks cannot bypass the allowlist.
- **Parity fixes.** The plan-rank table is shared in behavior, and auth files
  without an email get a stable name.
- **Build metadata.** macOS build 24; version metadata is aligned at 2.3.7.

## What's new in 2.3.6

- **Exact quota reserve.** macOS and Windows read live Codex quota signals every
  1.5 seconds and pause routing exactly at the selected reserve. The account
  card shows the actual stop value; a persisted pause clears after fresh quota
  recovery or a confirmed reset.
- **More reliable quota routing.** Gateway auth updates are diff-based, vault
  and quota-history writes are batched, and reset probes retry with backoff.
- **Windows welcome screen.** The onboarding dialog opens earlier, stays
  responsive while checks run, keeps its buttons visible, and uses the app's
  dark-and-gold palette.
- **Build metadata.** macOS build 23; version metadata is aligned at 2.3.6.

## What's new in 2.3.5

- **More provider connections.** DeepInfra and Vercel AI Gateway keys and model
  catalogs are available on macOS and Windows.
- **Connections page.** Provider cards now stack at full width. OpenRouter shows
  the available balance without a progress bar; the key-limit gauge and lifetime
  spend remain separate.
- **Build metadata.** macOS build 22; version metadata is aligned at 2.3.5.

## What's new in 2.3.1

- **Automatic recovery after capacity errors.** Codex's native Retry is pressed
  automatically while it is offered. When the retry budget is spent, Melon Tools
  sends a short continuation so a long task keeps moving without a manual click.
- **Quota-aware guard.** The watcher stays silent when every account is paused
  or the best 5-hour quota is at or below 5%, so a limit error does not produce a
  stream of continuation messages.
- **Visible control.** «Продолжать автоматически после перегрузки модели» is in
  Settings → Codex and on the Codex → Composer chips page. macOS build 21.

## What's new in 2.3.0

- Full audit remediation: test isolation, instance path safety, quota and
  scheduler hardening, CDP/log privacy, updater safety, and Windows parity.
- Provider-aware composer data, equal dashboard tiles, accessibility labels and
  Antigravity verification diagnostics.
- Release workflow now checks the requested tag, runs tests, verifies all
  assets and signs the portable before building the installer.

## Earlier: 1.6.3 «Security and data safety»

- **Hardened updater and secrets.** The Windows updater applies only the release it checked, the URL opener avoids cmd.exe, the management secret stays in the backend, helper processes are stopped by PID with identity checks, the engine binary is SHA-256 verified after extraction, and a restrictive CSP is set.
- **Data safety.** Atomic permission-preserving writes for secrets, config and auth files, bounded log rotation, backups and updater logs locked to 0600 under ~/Library/Logs.
- **UX fixes.** Claude disconnect clears its picker models, instance deletion asks for confirmation, Windows keeps unsaved inputs on background refresh, and login polls time out.

## What's new in 1.6.2 «Antigravity settings»

- **Consistent provider card.** The Antigravity card always shows «Обновить» and «Настройки»; connecting, cancelling and disconnecting live on the Antigravity settings page.

## What's new in 1.6.1 «Installer fix»

- **In-app installer reliability.** The update sheet closes before termination, a watchdog exits the app if termination is vetoed, and the swap script escalates to TERM/KILL instead of waiting on a hung process.

## What's new in 1.6.0 «Antigravity»

- **Google Antigravity joins the Providers page.** Connect a Google account via
  OAuth (engine-native, same pattern as Claude); the account email and project
  id land on the card, and the Antigravity models appear in the Codex picker.
- **Ownership-aware models.** Antigravity serves Gemini, GPT-OSS and even
  Claude-family ids; the model lists now separate them by the engine's
  `owned_by` field, so Claude and Antigravity never claim each other's models.
- **No invented quota.** The engine exposes no Antigravity quota API, so the card
  shows connection state, account, project and model count only.

## What's new in 1.5.0 «Claude provider»

- **Claude joins the Providers page.** Connect a Claude Pro/Max subscription with
  OAuth (the same client flow the Claude Code app uses) or fall back to an
  Anthropic console API key. Credentials are written as engine-native
  `claude-*.json` auth files and hot-load into the gateway.
- **Claude models in the Codex picker.** Selected `claude-*` models ride the new
  priority band 300 and appear in a Claude group after Apply + relaunch.
- **Claude bento card.** The Providers page shows the connection state, account
  email, plan, 5-hour and weekly quota windows with reset times, and the
  selected-model count. Numbers come from the account usage endpoint; missing
  data renders as «—» instead of made-up values.
- **Account-sync safety (both platforms).** Codex account sync now cleans only
  `codex-*.json` auth files, so Claude logins survive pool refreshes and quota
  ticks. Disconnect asks for confirmation.

## What's new in 1.4.8 «Update from GitHub»

- **In-app updates.** A full-width control sits in the sidebar above the
  status footer: «Проверить обновление» while up to date, switching to a gold
  «Обновить» button automatically when a newer GitHub release is known. It
  opens a window with the release notes and «Отмена» / «Обновить»;
  auto-check runs at most once a day.
- Downloads are verified against the release SHA256 (native GitHub asset
  digest or the `.sha256` file) before anything is installed; only HTTPS
  GitHub hosts are accepted.
- macOS swaps the bundle from the DMG after the app quits and relaunches it;
  Windows replaces its single executable the same way.

## What's new in 1.4.7 «Hardening»

- **Quieter when idle.** The gateway log tail runs every 2 s, the quota and
  chips timers carry tolerances, and Fleet polling only runs while a fleet or
  dashboard page is on screen.
- **Faster return from a tab.** Each section remembers its scroll offset —
  switching pages and coming back lands you where you left.
- **Cmd-1…9** jump straight to the first nine sidebar sections.
- The model catalog no longer bundles client-private prompt/policy fields.

## What's new in 1.4.6 «Fleet rebrand»

- **Full rebrand.** The fleet CLI, its env vars, and its home folder now use
  Melon Tools naming: the CLI is `melon-fleet` (bundled with the app), the
  env prefix is `MELON_FLEET_*`, and the workspace lives in
  `~/.melon-fleet`.
- **Quota reserve reacts fast now.** The quota refresh is adaptive: it keeps
  the configured interval when idle, but checks every ~30 seconds while the
  gateway is serving requests, so a 5% reserve pauses an account promptly
  instead of letting it burn to zero between five-minute checks. Same logic
  in the Windows build.

## What's new in 1.4.5 «Reliability fixes»

- **Codex no longer gets stuck after an account switch.** The auth file
  (`~/.codex/auth.json`) is now written in the full shape the Codex app
  expects: `auth_mode` and `tokens.account_id` are always present. Without
  them Codex logged “waiting for a ChatGPT account id” and blocked chatting
  with “failed to load workspace settings” — requests never reached the
  gateway.
- **Quota refresh now reaches the gateway live.** Account availability
  (paused / usable) is part of the routing signature, so both pause and
  unpause sync the gateway auth files on the refresh that landed them.
  Before, a window reset left the accounts disabled in the gateway until an
  unrelated sync happened.

## What's new in 1.4.4 «Smooth scrolling pass»

- **No shadowed scroll layers.** Card and sidebar shadows are gone: a layer
  with a shadow forces an offscreen render pass on every scroll frame and
  window animation on macOS. Hairline borders still separate the cards.
- **Pure-SwiftUI meters.** Quota and credit bars are capsule shapes scaled
  with a render transform — no hosted `ProgressView` per bar, and no
  `GeometryReader` inside scrolling content.
- **Light list rows.** The 300–470-row model lists use a static checkbox
  image with a whole-row tap instead of a hosted `Toggle` per row (re-hosting
  AppKit checkboxes while scrolling was a visible jank source).
- **Hover stays local.** Moving the pointer over the sidebar re-renders the
  row, not the whole layout including the active page behind it.
- **Quiet idle.** The 5s gateway health probe no longer publishes when
  nothing changed, and gateway/bridge log tails are internal state — no
  observer is invalidated by log traffic.
- **Universal, compressed engine.** The embedded gateway engine ships as a
  gzip-compressed universal binary (arm64 + x86_64), so the app bundle stays
  small; on first launch it is extracted into Application Support and verified
  by SHA-256 before every run. The DMG runs on both Apple Silicon and Intel
  Macs (macOS 14+).

## What's new in 1.4.3 «Donate & smooth GUI»

- **Donate page.** A new «Донат» sidebar item under Settings: USDT (TRC20)
  wallet with a QR generated on the fly by CoreImage (Vision-verified to
  decode back to the exact address) and a one-click copy button.
- **Smooth GUI.** Gateway log lines were published to every observer even
  though no view renders them — under agent load that invalidated the whole
  sidebar + active page dozens of times per second (the scroll/open/close
  lag). The log tail and the request journal are internal state now, the
  sidebar footer is its own tiny view, and status changes re-render only the
  footer.
- **Fleet without freezes.** CLI resolution is async (login-shell PATH probes
  no longer block the UI), streaming runs are cancellable with a Cancel
  button, console panes cap their buffer at 1000 lines and render lazily,
  result bodies read a bounded 512 KB prefix.
- **Account cards.** Horizontal quota bars instead of rings with
  two-component reset times — «через 1 ч 23 мин» for the hourly window and
  «через 6 дн 4 ч» for the weekly one. Deleting an account now asks for a
  confirmation.
- **Live pool load.** The pool popover shows «Запросы: N/мин» parsed from the
  gateway log — the actual load that burns the rolling windows.

## What's new in 1.4.2 «Providers, Go & hardening»

- **OpenCode Go models work now.** Models the Go plan covers ride the
  `/inference/go` endpoints (with the required `x-opencode-session` header), so
  they bill against the Go subscription. The generic surface — which answered
  "Insufficient account funds" despite an active Go plan — is kept only for
  models the Go plan does not include.
- **The account pool fails over properly.** Reserve thresholds and exhausted
  windows (0% left) now *exclude* an account from gateway routing until the
  next quota refresh, instead of only reordering it; stale quota readings never
  pause an account. The gateway also retries through cooling credentials
  (`request-retry: 3`, 45 s max wait, 20 s transient cooldown).
- **Accounts show subscription and resets.** Every Codex account card now has
  the subscription end date (with a relative reminder like “31 дн.”, or
  «Подписка истекла»), the reset-credit count with an availability hint
  («Нет доступных сбросов») and the nearest expiry, plus a warning when a 0 %
  weekly window blocks the 5-hour one. The subscription date is re-read from
  the backend every 30 minutes and falls back to the id_token claim.
- **Accounts page: selection + bulk actions.** Checkboxes on every account
  card, select-all, bulk quota refresh and bulk delete.
- **The «Models» page is now «Providers».** Three bento cards — the Codex
  account pool, OpenCode and OpenRouter — show each provider's live numbers.
  The pool card leads to Accounts; **Настройки** on a source card opens its
  key + model picker right inside the page.
- **Hardening pass.** Gateway PID/kill hygiene (identity check before
  SIGTERM/SIGKILL — no more blind lsof/PID-file kills), rollout parsing cache
  (no more 128 MB re-reads every 5 s), `~/.codex/config.toml` written 0600
  (it carries the bearer token), thread-safe log buffers in `ShellService`,
  device-login retry cap, unique gateway auth-file names, YAML-escaped config
  values, and a session-cost attribution fix (pool turns are no longer billed
  to OpenCode when a model id collides).
- **OpenRouter numbers are split by meaning.** The card shows the remaining
  balance (`total_credits − total_usage`, e.g. **$3.03**), the credits spent of
  those purchased (**$26.97 of $30**) and the key limit usage
  (**$0.09 of $1000**) as three separate tiles — the key limit is no longer
  mixed up with the balance.
- **The composer chip is one compact pill.** Both modes fit one chip: the pool
  shows `[Аккаунты 3 · 5 ч 200% · Неделя 180%]` — the pool's total capacity,
  summed across accounts, a third-party model shows `[OpenRouter ≈$0.09]` with
  the session spend of that provider. The popover carries the full breakdown
  and the refresh button stays.
- **Session spend is an honest estimate.** Every rollout turn is priced with
  the model that ran it (OpenRouter list prices, cache reads priced separately)
  and the numbers are split per provider: spend, tokens, cache share, turns.
  Missing prices are filled from the public OpenRouter model list on demand.
  Pool models have no public price, so they show a dash instead of a made-up
  number.
- **OpenRouter routes to the cheapest provider.** The gateway config adds a
  `payload.default-raw` rule that sets `provider: {"sort": "price"}` on every
  `openrouter/*` request (price-verified end-to-end through CLIProxyAPI).
  OpenRouter aliases now carry the `openrouter/` prefix; older stores migrate
  on load.
- **The picker is grouped by provider.** The Codex model menu shows
  **OpenAI**, **OpenCode** and **OpenRouter** headers with the models of each
  provider underneath (and a small provider tag on every third-party row).
  The catalog builder assigns the order with priority bands — the pool keeps
  0…8, OpenCode starts at 100, OpenRouter at 200. A stale catalog (written by
  an older build) is regenerated automatically at app launch.
- **Sources load at launch.** The model-source store is now read when the app
  starts, so a gateway restart keeps the `api-keys.openai-compatibility`
  block instead of dropping it until the Providers page is opened.

## What's new in 1.4.0 «Model sources & Bento»

- **Models page with key-based sources.** A new **Codex → Models** page connects
  **OpenRouter** and **OpenCode** by API key: paste the key, load the account
  model list, tick the models you want. The pool models stay always available.
- **The Codex picker is generated.** Applying writes
  `~/.codex/melon-model-catalog.json` — the pool catalog plus one entry per
  selected model (slug, display name, context window, auto-compact limit) — and
  points `model_catalog_json` in `~/.codex/config.toml` at it. Selected models
  appear in the Codex composer after a relaunch.
- **One gateway config for everything.** Selected models ride in the same
  gateway service (`api-keys.openai-compatibility`), hot-reloaded — no restart:
  OpenRouter models keep their raw ids (`z-ai/glm-5.3-flash`), OpenCode models
  are aliased as `opencode/<model>`.
- **Bento layout.** The sidebar is one solid card on the app canvas; the content
  area is a stack of cards. Timers were reworked: batched log ingestion, change
  detection on fleet polling, cached process discovery, wider probe intervals.

## What's new in 1.3.3 «Glass & brand»

- **Frosted chips popover.** The «Account status» popover in the Codex composer
  now sits on a frosted-glass surface: 30 px blur with saturation over a
  72–78% opaque tint (dark/light), readable in both themes. The popover had no
  background at all — its palette custom properties were bound to
  `.melon-chips` while the popover is attached to `document.body`.
- **Technical text out of the UI.** The API Service page drops the port field,
  the raw endpoint lines, and the requests/log cards; Settings drops the
  «Paths» and «Diagnostics» cards; the composer page drops the debug-port line
  and the event log. What stays in «Client setup» is everything needed to
  connect other tools: Base URL and API key, each with a copy button.
- **Cleaner Fleet pages.** Fleet pages use `fleet …` kickers, the Call and
  Rules consoles print human status lines instead of shell commands, and
  exit pills read **Done / Tool error / Failed (n)**.
- **Brand refresh.** The new melon-and-wrench logo appears in the sidebar, the
  menu bar extra, and About; the app icon and the DMG volume icon are drawn
  from the new artwork.

## What's new in 1.3.2 «Pool routing»

- **The API control card moved to API Service.** The full «API control»
  block — gateway state, launch, and pool routing — now lives on the
  **Codex → API Service** page. **Codex → Accounts** gets a compact twin as
  the first card in the grid: state, address, routing mode, queue preview,
  and **Launch Codex** / **Manage** buttons.
- **Per-account limits with automatic switching.** Each account can set
  “pause” thresholds for the 5-hour and weekly quota — for example, switch
  away when the 5-hour quota left drops to 10%. When a threshold is hit, the
  planner demotes the account and the next one takes over live (the gateway
  hot-reloads auth files, no restart); the account returns automatically
  when its quota recovers.
- **Account priority and roles.** Mark an account **Always first** (it leads
  the queue while usable) or **Backup** (used only when the regular accounts
  are unavailable).
- **Cross-provider JSON import.** One Cockpit/CPA or sub2api export can carry
  Codex, Claude and Antigravity logins; Codex accounts join the vault and the
  other providers are written to the engine auth directory.
- **Seven routing modes**, mirroring Cockpit Tools: **Auto (recommended)**,
  **Most quota left first**, **Least quota left first**, **Top plan first**,
  **Lower plan first**, **Expiring soon first**, and **Manual order** with
  reorder arrows. The gateway runs fill-first over the computed priorities:
  the top account serves until it is exhausted, then the next takes over.
- **No technical paths in the UI** — raw file paths in normal screens are
  replaced with plain wording (import, route status, instances, diagnostics).
- **Consistent naming.** The brand is simply **Fleet** everywhere in the UI.

## What's new in 1.3.1 «Launch the app»

- **Every “Launch Codex” button opens the app.** The buttons in the API
  Service page, Settings, and the account rows no longer open Terminal with
  the CLI — they start the gateway when needed, write the route, and restart
  the Codex app, exactly like the card in **Accounts**.
- **Fresh settings on every launch.** Each launch restarts the app (like
  Cockpit Tools does for its default instance), so it always rereads
  `~/.codex/config.toml` and comes up with the current routing.
- **Chips always come back.** While the Melon route is active, a Codex app
  that is running without the debug port (for example, started from the Dock)
  is relaunched automatically so the composer chips attach. An app that
  ignores the quit request is force closed after a graceful wait.

## What's new in 1.3.0 «API Control»

- **Main API control card** — a permanent first card in **Codex → Accounts**.
  It manages the local API service end to end (status, copy URL, check API,
  restart, stop) and adds **Launch Codex**: one click points the Codex app at
  the gateway — the previous `~/.codex/config.toml` is backed up, the route is
  written, and the app relaunches with the debug port so the chips reconnect.
  **Remove routing** restores the backed-up config and relaunches the app.
- **Account routing strategies** — «Even» spreads requests across the pool
  (round-robin); «By priority» is fill-first: the top account serves until it
  is exhausted, then the next one. Reorder with the arrows and press
  **Apply routing** — the gateway restarts with the new strategy and the
  priorities land in the account auth files.
- **Solid surfaces everywhere** — Liquid Glass styling is gone from the app
  and from the injected composer chips: flat cards, buttons, and popovers
  with higher contrast in both themes.
- **Startup safety** — a `model_catalog_json` reference to a missing file
  (left behind when another route tool removes its catalog) stops the Codex
  app from starting. Melon Tools now drops the dangling key while its route
  is active; the backup restores the line on «Remove routing».

## What's new in 1.2.1 «Chips»

- **Compact traffic panel** — the «Recent requests» list in **Codex → API
  Service** is now a fixed-height card with its own scroll, so it stays
  compact no matter how much traffic flows through the gateway.

## What's new in 1.2.0 «Chips»

- **Composer Chips for the Codex app** — Liquid Glass chips right in the Codex
  composer: account count, 5-hour and weekly quota, one-click refresh, and an
  «Account status» popover with per-plan quotas and pool health
  (working / failed / paused). Russian by default — the chips follow the app
  language.
- **Zero-footprint injection** — the chips live over a local DevTools
  connection to the Codex app. Nothing on disk is patched, no ports are opened,
  no tokens are shared: Melon Tools pushes the pool snapshot, the chips push
  back refresh requests. The Codex app is relaunched with a loopback debug port
  automatically.
- **Graceful lifecycle** — when Melon Tools quits, the chips dim and keep the
  last values; they reconnect on the next launch. Turning the feature off in
  **Codex → Composer Chips** removes them instantly. The chips adapt to the
  composer width: full → accounts + refresh → hidden.

## What it does

### Scheduler
A small, local task scheduler that runs while Melon Tools is open:

- **Tasks** — name, prompt, model (from the local gateway: pool, OpenCode,
  OpenRouter, Claude, Antigravity), optional reasoning effort and interval.
- **Run now / enable toggle** — manual runs always work; enabled tasks run on
  their interval through the local gateway (`/v1/chat/completions`).
- **Results and history** — the last result, duration and tokens per task, with
  bounded history (20 entries per task, 200 in total) in
  `~/Library/Application Support/MelonTools/scheduler.json` (0600).
- **No background agent** — tasks run only while the app process is alive; a
  missed run fires once after wake/relaunch, never as a burst.

### Codex
Re-implemented from scratch on top of the official OAuth/API endpoints:

- **Accounts** — a local vault of ChatGPT subscription accounts. Import the
  current `~/.codex/auth.json`, paste an auth payload, or sign in with the
  device flow. Per-account hourly/weekly quota rings from
  `chatgpt.com/backend-api/wham/usage`, reset-credit count, one-click switch
  (writes `~/.codex/auth.json`, keeps a backup), proactive token refresh.
- **API Service** — a local OpenAI-compatible gateway (CLIProxyAPI engine,
  MIT, embedded) that serves your account pool on `http://127.0.0.1:18317`
  with a generated API key. Start/stop, health check, client setup snippets.
  Any OpenAI-compatible tool can point at it. The control card in
  **Accounts** keeps it at hand: launch the Codex app on the gateway in one
  click, switch the routing strategy, reorder account priorities.
- **Composer Chips** — solid status chips inside the Codex app composer:
  accounts count, 5-hour and weekly quota, one-click refresh, and an
  «Account status» popover. Injected over a local DevTools connection — no
  files patched, no ports opened; chips dim when Melon Tools is off and are
  removed when the feature is disabled.
- **Instances** — parallel Codex CLI sessions, each with its own `CODEX_HOME`
  and bound account; launch opens Terminal with the isolated environment.

## Requirements (runtime)

| Component    | Why                                   | How to get              |
|--------------|---------------------------------------|-------------------------|
| macOS 14+    | App baseline                          | —                       |
| Universal    | arm64 + x86_64 in one build           | —                       |
| Codex CLI    | Instances (optional)                  | `npm i -g @openai/codex`|
| Codex app    | Composer Chips (optional)             | openai.com/codex        |

## Build from source

Prerequisites: Xcode (27+), XcodeGen (`brew install xcodegen`), Go 1.26+
(`brew install go`). `create-dmg` (`brew install create-dmg`)
is optional — the script falls back to a plain `hdiutil` image.

```bash
./build.sh            # full pipeline: gateway → icon → xcode → dmg
open build/MelonTools-3.4.0.dmg
```

The app is ad-hoc signed (personal build, not notarized). On first launch use
**right-click → Open**, or clear the quarantine flag:
`xattr -dr com.apple.quarantine "/Applications/Melon Tools.app"`.

Individual steps:

```bash
# Full pipeline: gateway (universal), icon, xcodegen, Release build, ad-hoc
# signing and DMG. There is no arm64-only recipe: the embedded gateway must
# carry both slices for Intel Macs.
./build.sh

# Xcode-only inner loop (expects build/cliproxyapi to exist):
cd app && xcodegen generate
xcodebuild -project MelonTools.xcodeproj -scheme MelonTools \
  -configuration Release -derivedDataPath "$HOME/Library/Developer/MelonTools" \
  CODE_SIGNING_ALLOWED=NO build

# Manual signing order: engine first, then the app (never --deep):
codesign --force --options runtime --timestamp=none --sign - \
  "$HOME/Library/Developer/MelonTools/Build/Products/Release/MelonTools.app/Contents/Resources/bin/cliproxyapi"
codesign --force --options runtime --timestamp=none --sign - \
  "$HOME/Library/Developer/MelonTools/Build/Products/Release/MelonTools.app"
```

## Layout

```
app/                          XcodeGen project + Swift sources
  project.yml                 target definition (embed scripts live here)
  MelonTools/
    Core/                     AppState, ShellService (Process wrapper)
    Design/                   MTTheme tokens, MTComponents
    Scheduler/                Task models, store, gateway runner
    Codex/                    Accounts, OAuth/quota service, gateway service
    Views/                    Dashboard, Scheduler, Codex views, Settings
  Resources/                  AppIcon.icns, Logo.png (bundled artwork)
scripts/
  assets/                     icon + logo sources used by build.sh
  trim-logo.swift             crops transparent margins from the logo source
  make-icon.swift             legacy icon generator (unused)
  test-gateway.py             smoke-test for the gateway config shape
_sources/
  CLIProxyAPI/                gateway engine (MIT)
build/                        artifacts (gateway binary, icon, dmg)
```

## Data locations

| What                  | Where                                              |
|-----------------------|----------------------------------------------------|
| Account vault         | `~/Library/Application Support/MelonTools/codex/accounts.json` (0600) |
| Gateway config        | `~/Library/Application Support/MelonTools/gateway/config.yaml` |
| Gateway account files | `…/gateway/auths/codex-*.json`                    |
| Instances             | `…/MelonTools/instances/<name>/codex-home/`       |
| Scheduler tasks       | `…/MelonTools/scheduler.json` (0600)              |

## Licensing notes

- The gateway engine is **CLIProxyAPI** (MIT), built from source.
- The Codex flows are a clean-room re-implementation of visible behavior
  against public endpoints; no cockpit-tools code was copied.
- This is a personal tool. You are responsible for how you use your accounts.

### Provenance (this build)

| Component      | Version | Commit                                    |
|----------------|---------|-------------------------------------------|
| CLIProxyAPI    | v8 tree | `1f917e77c4562623aa49e9804d999524151a2f96` |
