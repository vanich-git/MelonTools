# Melon Tools 6.0.0-rc.1

Release candidate for macOS and Windows. **This is a test build, not a stable
release.** 6.0.0-rc.1 is published as a GitHub **prerelease**: it is not
"latest", it does not replace 5.5.8 in Homebrew or winget, and the in-app
updaters ignore it because they read `/releases/latest`. Homebrew, winget and
the download README keep describing the last published 5.5.8 artifacts until
6.0.0 passes acceptance and is promoted. See `packaging/README.md` and
`docs/RELEASE_ACCEPTANCE.md`.

> **Read before installing**
>
> - **macOS: ad-hoc signed, not notarized.** Gatekeeper blocks the first
>   launch. Use right-click → Open (or System Settings → Privacy & Security →
>   Open Anyway) only after the downloaded file matches its `.sha256` sibling.
>   Developer ID signing and notarization stay blocked until the Apple secrets
>   are configured.
> - **Windows: not Authenticode-signed.** SmartScreen may show "Windows
>   protected your PC" and refuse the first launch. Choose **More info → Run
>   anyway** only after the SHA-256 matches. The installer is per-user and does
>   not request elevation.
> - **Release-candidate quality.** Settings, the model storage layout and the
>   local-AI API can still change before 6.0.0. Back up anything you cannot
>   download again, and do not hand this build to other people.
> - **Local AI is hardware-hungry.** No GGUF model is bundled: models are
>   downloaded on demand and can be many gigabytes. Expect high RAM/VRAM use
>   and a slow first load; throughput depends on the machine.
> - **Verify every download.** Each asset has a `.sha256` sibling, and the
>   release body lists all digests.

## What is in 6.0.0

- **Local AI on both platforms.** Melon Tools runs GGUF models with a bundled
  `llama-server` and exposes them through the existing loopback gateway
  (`127.0.0.1:18318`), so Codex and other clients reach local models through
  the same OpenAI-compatible endpoint.
- **Bundled, verified runtime.** The macOS bundle ships a pinned universal
  llama.cpp runtime (`b12099`, arm64 + x86_64) with its dylib closure and a
  SHA-256 manifest. Runtime downloads, lipo merging, signing and manifest
  refresh are handled by `MacOS/scripts/fetch-runtime.sh`; an arm64-only
  runtime is rejected before the DMG is built.
- **Model management.** Model registry with per-model directories, split-model
  validation, resumable Hugging Face downloads, storage settings and hardware
  recommendations. The storage layout is documented in
  `docs/LOCAL_AI_ARCHITECTURE.md`.
- **Release hardening.** Clean checkouts fetch and verify the runtime before
  the first XcodeGen run; signed releases re-sign the nested runtime binaries
  and refresh the runtime digest before the app bundle is sealed. Native
  acceptance checks are described in `docs/RELEASE_ACCEPTANCE.md`.

## What this RC does not prove

- **No Developer ID, no notarization.** The macOS DMG is ad-hoc signed; the
  `spctl` and stapled-ticket checks in `MacOS/scripts/native-acceptance.sh` are
  skipped without certificates.
- **No Authenticode.** Windows signing steps are skipped when the certificate
  secrets are absent, so SmartScreen reputation is untested.
- **No interactive Windows install/upgrade/soak run.** CI builds the installer
  and portable exe on a native Windows runner and validates PE headers, hashes
  and the legacy alias. Clean install, upgrade from 5.5.8,
  uninstall, WebView2 IPC and DPAPI behaviour remain manual checks in
  `docs/RELEASE_ACCEPTANCE.md`.
- **No Homebrew/winget promotion.** Both manifests intentionally still point at
  5.5.8 with its published hashes; promotion applies to stable releases only.

## 5.5.8

Windows expansion reliability fix.

- **Second window instead of resize.** The compact pill and the 420×242 card
  are separate native windows. Clicking the pill shows the card and hides the
  pill, so no WebView2 surface resize can leave an empty compact strip.
- **CSS collision fixed.** `.expanded` also matched `<body>`, hiding the whole
  panel document. The body state is now `island-open`, and the hide rule is
  scoped to `.island > .expanded`.
- **Configurable auto-fold.** The Windows Settings page offers Immediately / 5 /
  10 / 15 / 20 seconds for the large card; the default is 15. Immediately
  folds it as soon as the pointer leaves; × closes it at any time.
- **Build metadata.** macOS build 55 and Windows 5.5.8.

## 5.5.7

Windows island interaction and compact-metrics fix.

- **Compact metrics.** The pill now shows the 5-hour pool total, the weekly
  pool total, the number of connected Codex accounts, and the API status dot,
  in that order. The dot is green while the gateway is running.
- **Click opens; no hover resize.** The compact island stays put on hover. A
  click expands the card with one native resize and the existing fade.
- **15-second auto-fold.** After the pointer leaves the open card it folds back
  after 15 seconds; returning cancels the timer. Escape closes it immediately.
- **No tween loop.** Tweening `set_size`/`set_position` on Windows emitted
  mouseleave events and made the card collapse and jump; the resize is now a
  single call.
- **Build metadata.** macOS build 54 and Windows 5.5.7.

## 5.5.6

Island shape and interaction fix.

- **One silhouette.** Both apps now render the island flush with the top edge
  with only the bottom corners rounded (18 pt). Windows no longer rounds the
  top corners, which made the compact pill look detached from the screen edge.
- **Windows opens on click.** Hovering the compact island no longer resizes the
  native window, which caused a mouseleave/resize loop and made the island
  flicker or disappear. A click expands it with a 220 ms size tween and the
  existing content fade; leaving the card or pressing Escape collapses it.
- **Build metadata.** macOS build 53 and Windows 5.5.6.

## 5.5.5

Status island release: the macOS and Windows apps now share a compact
top-of-screen HUD, and the audit findings around pointer tracking, polling and
window handling are fixed.

- **Status island.** Borderless panel at the top edge. On macOS it follows the
  camera cut-out; on Windows it is centred on the primary monitor. Resting
  layout is a compact pill, or one continuous bar with hourly and weekly totals
  beside the cut-out. Hover opens the pool, Antigravity, providers, scheduler
  and Open / Pause API / Run.
- **Geometry.** The side-by-side layout keeps its 30 pt height on displays
  without a notch; the window frame is always the open size, so the top edge
  never moves during the 0.28 s expansion.
- **Pointer and redraws.** Global mouse tracking is throttled to 30 Hz and is
  removed when the island is hidden. The SwiftUI view observes a small
  `NotchHUDMetrics` snapshot instead of every store, so QoS samples and busy
  account changes no longer redraw it.
- **Windows.** The status payload is cached for four seconds, `island_run_next`
  returns immediately and runs the task in the background, polling pauses while
  the island is hidden, and the webview is created only when enabled.
- **Small fixes.** "Open" unminimises the main window; Start and Run have
  different Russian labels; language changes reach the island; the target
  screen lookup no longer indexes an empty array.

> **Signing note:** the macOS build is ad-hoc signed and not notarized; the
> Windows executable is not Authenticode-signed, so Windows Defender SmartScreen
> may show "Windows protected your PC". Choose **More info → Run anyway** only
> after verifying the download against its `.sha256` file or `SHA256SUMS`.

## 5.0.1

Maintenance release: the Windows Antigravity controls work again, the idle
quota guard stops polling the gateway every 1.5 seconds, and the Antigravity
card no longer expands into a wall of unavailable models.

- **Antigravity controls on Windows.** Pause, resume, priority, remove and
  probe were rejected by the IPC bridge whitelist; the command is allowed
  again, so the account buttons work.
- **Quota guard back-off.** A blocked account keeps the 1.5 s guard only while
  its window resets within five minutes; otherwise it polls every 15 s. On an
  idle pool this cuts roughly 40 management requests a minute — and ~30 MB of
  gateway log per day — to a handful, and removes the daily log-rotation
  restart.
- **Compact Antigravity card.** The catalog-only model list is collapsed
  behind a disclosure row with a count; expanding it shows a bounded grid, so
  the card keeps its size even with dozens of unavailable ids.
- **Quieter diagnostics.** Lifecycle, gateway and updater events are written
  to the unified log instead of being invisible.
- **Docs and manifests.** `packaging/README.md` and `docs/SECURITY-MODEL.md`
  match 5.0.1, the dead `claude_refresh`/`antigravity_refresh` commands are
  gone, and `cargo fmt --check` is clean again.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v5.0.1/MelonTools-5.0.1.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v5.0.1/MelonTools-5.0.1-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v5.0.1/MelonTools-5.0.1-win-x64-portable.exe)

### SHA-256

```
b7df0562c73db8091fe3b7b76799546c74d14263973fdb4ef684b38ab1dec7a7  MelonTools-5.0.1.dmg
8ca179ea5940b6a5f394b3a75903bae52a832bc2ead4ee2fa24d633ae871a291  MelonTools-5.0.1-setup.exe
930a6e3b355192467f89fb30d2874612b4a923affb62abf6ee99ba7a099856e2  MelonTools-5.0.1-win-x64-portable.exe
```

# Melon Tools 5.0.0

A ground-up visual redesign on macOS and Windows: one flat dark canvas, bento
cards, a floating sidebar and a semantic accent palette. Routing, quota and
scheduler behaviour is unchanged.

- **Flat dark canvas.** The window paints one `#111113` surface behind the
  sidebar and the board; cards are `#1F1F22` plates with an 18 pt radius and a
  neutral hairline. The coloured accent frames, radial glows, drop shadows and
  per-card backdrop blurs are gone, which also removed the per-frame
  rasterisation that made long boards stutter while scrolling.
- **Floating sidebar.** Navigation sits on its own plate with a per-section
  accent: a selected row takes a soft tint of that accent, a matching glyph and
  a trailing dot. Hover stays a neutral `white 6%` wash.
- **Bento dashboard.** The overview is two equal columns whose cards stretch to
  the row height, so a short card never leaves a hole under itself. New
  **Providers** and **Account pools** cards answer "what is connected" without
  opening a second page: every upstream (Codex OAuth, Antigravity, Claude,
  OpenRouter, OpenCode, DeepInfra, Vercel, Z.ai) with its model count, and each
  pool (Codex, Antigravity with Gemini/Claude windows, Claude) with its account
  count and remaining quota.
- **Pool totals, not averages.** "Codex pool health" and the status bar panel
  sum the remaining quota across the pool: five accounts at 100% read **500% of
  500%** for the 5-hour window, matching the account cards instead of showing an
  average of 100%.
- **Status bar panel.** The menu extra drops the account list, uses SF Pro
  instead of the monospaced data face, gains rounded hover states on every row,
  shows the pool totals and the single gateway status line (the duplicated
  "service running running" string is gone).
- **Windows parity.** The Tauri shell ships the same palette, radii, flat
  plates, hero banner, provider and pool cards, per-section navigation accents
  and the same summary maths; only the system font differs (Segoe UI instead of
  SF Pro).
- **New identity.** The amber melon-slice icon and the transparent logo ship in
  both apps: Dock icon, About sheet, sidebar, dashboard hero and the Windows
  installer icon.
- **Build metadata.** macOS 5.0.0 (build 50); Windows 5.0.0.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v5.0.0/MelonTools-5.0.0.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v5.0.0/MelonTools-5.0.0-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v5.0.0/MelonTools-5.0.0-win-x64-portable.exe)

### SHA-256

```
436732a5117b56f451d0a65f79a68556f7fda18786596326c282dc5832ac58c4  MelonTools-5.0.0.dmg
6cf1a3ab6373962286591bc6f8681af90bf24385baad9c1c9a6fdeaad898cd01  MelonTools-5.0.0-setup.exe
97b66b6da08058523d7d0b1160d505a79c02abc0525fbd69c96795ee454b4ea1  MelonTools-5.0.0-win-x64-portable.exe
```

# Melon Tools 4.0.1

Maintenance release: probe clears every Antigravity cooldown, the pool polls
less while idle, long-running logs rotate, and the quarantine badge names its
reason.

- **Probe releases every model.** One first-token timeout can quarantine
  several models of the same account, because the engine keys the watchdog by
  auth/model. A successful probe now clears all of them on macOS and Windows;
  before, only the first cooldown was released and the account looked
  quarantined until the next probe.
- **Idle pool stops calling Google every five minutes.** The macOS quota poll
  now follows gateway load like the Windows loop already did: 60 s while
  requests are running, 15 min when the pool is idle. The 5-hour windows only
  move under load, so this drops battery use and avoids rate-limiting the
  quota endpoint.
- **Logs rotate during long sessions.** `gateway.log` used to be rotated only
  when the engine restarted, so a machine left running for weeks kept growing
  the file. The watchdog now rotates it once the file passes 32 MB, and only
  while the pool is idle so an active stream is never cut.
- **The quarantine badge names its reason.** A red row now says whether the
  first token timed out (QoS watchdog), the Google quota window is exhausted,
  Cloudflare challenged the request, or the sign-in/plan needs attention.
  macOS and Windows show the same labels in Russian and English.
- **Build metadata.** macOS build 41 and Windows 4.0.1; version metadata is
  aligned at 4.0.1.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v4.0.1/MelonTools-4.0.1.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v4.0.1/MelonTools-4.0.1-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v4.0.1/MelonTools-4.0.1-win-x64-portable.exe)

### SHA-256

```
aa3edd02d256613a8ddb919abd33a766b3026d7a36ac14890da90c2ca65af91a  MelonTools-4.0.1.dmg
5a3ab2fa8fc1ab493feaa3e29a7b58f5dfad69fbea5d38df3a9dd6ad7250bee3  MelonTools-4.0.1-setup.exe
6c89e946196a74dac06a6e2e4fa03427ae234901cb8775d58a0b3ff3b6eb181e  MelonTools-4.0.1-win-x64-portable.exe
6c89e946196a74dac06a6e2e4fa03427ae234901cb8775d58a0b3ff3b6eb181e  MelonTools-4.0.1-win-x64.exe
```

# Melon Tools 4.0.0

> **Repository move:** Melon Tools now lives at
> [`vanich-git/MelonTools`](https://github.com/vanich-git/MelonTools). Releases
> before 4.0.0 were published from the previous repository and their download
> links no longer resolve; the changelog below is kept for history.

Antigravity becomes a real account pool, shows its 5-hour quota, explains
catalog-only models, and fails over before a slow first token reaches the
client.

- **Multi-account Antigravity pool.** Connect any number of Google accounts;
  each one gets its own row with identity, project, model count, pause/resume,
  sign-in refresh and per-account removal. The engine routes across the pool,
  and the UI no longer collapses everything to the newest auth file.
- **Quota that is actually available.** `fetchAvailableModels` exposes
  `quotaInfo` per model. The app groups it into the two pools Google uses
  (Gemini and Claude/GPT), shows the remaining share of the current 5-hour
  window and its reset time for every account. The weekly Antigravity window is
  not exposed by the API and is not fabricated.
- **Catalog-only models are labelled.** A grey block lists ids present in the
  catalog but absent from every connected account, with the reason: the model
  is defined, the account is not entitled to it (plan or region).
- **Antigravity first-token failover.** New engine key
  `stream-bootstrap-timeout-seconds` (0 disables, default 60), scoped to
  Google/Antigravity streaming accounts. If no first payload arrives before the
  deadline, the engine retries the request on another Antigravity account before
  headers are committed. The slow account gets a quarantine ladder of
  60 s → 5 min → 30 min → 2 h. Codex, Claude and API-key providers keep their
  previous behaviour.
- **Health probe and telemetry.** A quarantined account can be probed with a
  lightweight model-list request; a success clears only the first-token
  cooldown. The Providers card shows the latest TTFT or the last switch, and
  every switch is written to the audit log. macOS and Windows share the same
  behaviour.
- **Update checks follow the new repository.** The in-app updater on macOS and
  Windows now asks `api.github.com/repos/vanich-git/MelonTools`. Builds older
  than 4.0.0 still look at the retired `ivankuprin/MelonTools` repository and
  cannot see this release, so install 4.0.0 manually once; later updates work
  from inside the app.
- **Build metadata.** macOS build 40 and Windows 4.0.0; version metadata is
  aligned at 4.0.0.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v4.0.0/MelonTools-4.0.0.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v4.0.0/MelonTools-4.0.0-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v4.0.0/MelonTools-4.0.0-win-x64-portable.exe)

### SHA-256

```
3deb12c07d59f6bcf12bf0717d455bcb495713f31327ea01eec04eb2abb13220  MelonTools-4.0.0.dmg
f515ef6d0abb86690b070f1eb5b0f88532079ba5e7ba0fbb7d22851ce3f0ab1d  MelonTools-4.0.0-setup.exe
6bba8457add3a0c347e3a39fca6c2a568f47f74108a318e79f01df4c2ba7bab8  MelonTools-4.0.0-win-x64-portable.exe
6bba8457add3a0c347e3a39fca6c2a568f47f74108a318e79f01df4c2ba7bab8  MelonTools-4.0.0-win-x64.exe
```

# Melon Tools 3.4.2

The three Antigravity models Google entitles on the account but the engine
catalog omitted now reach the Codex picker on macOS and Windows.

- **Gemini 3.8 Flash (Low) and (Medium).** Google lists both thinking levels as
  separate ids (`gemini-3.8-flash-low`, `gemini-3.8-flash-medium`) with their own
  quota. The engine catalog ships only `gemini-3.8-flash-high`, so the two ids
  never passed the catalog ∩ account intersection. Both now reach `/v1/models`
  and the picker.
- **Gemini 2.5 Pro.** `gemini-2.5-pro` is entitled on the Antigravity account but
  was absent from the Antigravity section of the engine catalog. It is now
  served through the same provider.
- **Written by the app.** The app fetches the official catalog, adds the three
  definitions, validates the result and writes `gateway/models.json`;
  `config.yaml` points `models.catalog` at that file, so the fix survives
  restarts and settings saves. The engine binary is unchanged.
- **Safe refresh.** The overlay follows the engine's three-hour catalog cadence,
  deduplicates every section before writing (one duplicate id makes the engine
  reject the whole catalog), and retries fifteen minutes after a failed fetch.
- **Both platforms.** macOS and Windows write the same file and YAML block.
- **Plan-gated ids stay hidden.** Claude Opus/Sonnet 5.5 and Gemini 4 Argon
  are already in the official catalog, but the engine serves only ids the
  signed-in Google account reports. They appear automatically when the
  plan includes them; the overlay never force-adds an unentitled id.
- **Build metadata.** macOS build 39 and Windows 3.4.2; version metadata is
  aligned at 3.4.2.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.4.2/MelonTools-3.4.2.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.4.2/MelonTools-3.4.2-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.4.2/MelonTools-3.4.2-win-x64-portable.exe)

### SHA-256

```
624c90b7bd8a17fba827fc8e9c93405d749465478c9ef4bdce9dbcd48fc8db61  MelonTools-3.4.2.dmg
fa3a7fb206008bf584ec61303f25b89e89cac320a59fe0d9d3adbb21706d01e5  MelonTools-3.4.2-setup.exe
f6e35fe81d77905b5b534f132f80f01e1770497f515d5c7c69868640237323df  MelonTools-3.4.2-win-x64-portable.exe
f6e35fe81d77905b5b534f132f80f01e1770497f515d5c7c69868640237323df  MelonTools-3.4.2-win-x64.exe
```

## 3.4.1

Proxy URL saving, proxy authentication, and the Z.ai provider.

- **Explicit proxy URL save.** A round gold check button appears to the right of
  the proxy URL field as soon as the value differs from the saved one. Click it
  (or press Return) to apply the URL and show a short “Saved” confirmation.
  Windows gets the same button and toast.
- **Authenticated SOCKS and HTTP proxies work.** The macOS proxy dictionary now
  carries `SOCKSUser`/`SOCKSPassword` and the HTTP/HTTPS credential fields.
  Previously an authenticated SOCKS5 URL produced `NSURLErrorBadURL`
  («неверный URL») on every quota refresh even though the local gateway and
  DSH kept working.
- **Z.ai GLM Coding Plan provider.** A new API-key source on macOS and Windows:
  paste a key from Personal Coding Plan → Plan Overview, load the model list,
  and use GLM-5.3 / GLM-5.3-Flash through the Coding endpoint
  `https://api.z.ai/api/coding/paas/v4`. The built-in catalogue is used when
  `/models` is unavailable.
- **Build metadata.** macOS build 38 and Windows 3.4.1; version metadata is
  aligned at 3.4.1.
- **Windows switches render correctly.** The settings, dashboard and account
  toggles use a clean pill with a properly inset knob instead of inheriting the
  square-checkbox checkmark.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.4.1/MelonTools-3.4.1.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.4.1/MelonTools-3.4.1-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.4.1/MelonTools-3.4.1-win-x64-portable.exe)

### SHA-256

```
fe3e9956dd067de43cbabc08375f2495fca823a533792cb464a13f2ff35b8677  MelonTools-3.4.1.dmg
72b42da27e0689ea1d436aa635cc6847e12e8707e9509ef9b48767d561c36d75  MelonTools-3.4.1-setup.exe
ac035405a320b3ee0690b7627a28dece7050f6f497bc92ddda68e9ce19f4ab6a  MelonTools-3.4.1-win-x64-portable.exe
ac035405a320b3ee0690b7627a28dece7050f6f497bc92ddda68e9ce19f4ab6a  MelonTools-3.4.1-win-x64.exe
```

## 3.4.0

Reset credits are now redeemable from the Codex account card on macOS and Windows.

- **The counter is a button.** When an account has banked resets, the card
  shows an active gold button — «1 сброс», «2 сброса», «5 сбросов» — instead
  of a read-only counter. With zero credits the old “Нет доступных сбросов”
  label remains.
- **Confirmation before spending.** The button opens a confirmation dialog
  that names the account and explains that one credit will clear the current
  Codex usage limit.
- **The nearest expiry is redeemed first.** The app reads the reset-credit
  records and sends the id of the soonest-expiring credit; a request id makes
  the consume call idempotent, so a retry cannot spend a second credit.
- **Clear outcomes.** Success, “nothing to reset”, “no credit” and “already
  redeemed” are reported in the message card. Quotas refresh immediately after
  redemption, and the button shows a spinner while the request is in flight.
- **Windows parity.** The Windows app gets the same gold reset button, native
  confirmation, backend consume call, in-flight guard and immediate quota
  refresh.
- **Build metadata.** macOS build 37 and Windows 3.4.0; version metadata is
  aligned at 3.4.0.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.4.0/MelonTools-3.4.0.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.4.0/MelonTools-3.4.0-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.4.0/MelonTools-3.4.0-win-x64-portable.exe)

### SHA-256

```
b604bc8cfc9fb69ac75a6fe6511c655f810c4c828b831644120e71933d574ded  MelonTools-3.4.0.dmg
bef5cfcaea2612f213cb4d39601376ee44777396814743a90017bf6a4da600ba  MelonTools-3.4.0-setup.exe
877dbe803f56a8c7723ea22e0888759d5e5d53e7263106f14a266bc7c5a3c0b4  MelonTools-3.4.0-win-x64-portable.exe
877dbe803f56a8c7723ea22e0888759d5e5d53e7263106f14a266bc7c5a3c0b4  MelonTools-3.4.0-win-x64.exe
```

## 3.3.0

Windows stability fixes and cross-provider JSON import.

- **Codex history survives the gateway.** Melon changes only the top-level
  `model_provider` and its own provider table. Every other
  `[model_providers.*]` table is preserved, and the legacy
  `codex_local_access` alias is written automatically so old chats open and
  route through Melon instead of failing with “Model provider not found”.
- **No more `app.lock` startup hang.** Single-instance ownership moved to a
  named OS mutex. A crash releases it automatically, so a stale
  `%APPDATA%\MelonTools\app.lock` cannot block the next launch.
- **No zombie `cliproxyapi.exe`.** The engine is assigned to a Windows Job
  Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; closing Melon — even
  abnormally — also terminates the engine and frees port 18317.
- **The window comes back from the tray.** Launching the shortcut while Melon
  is hidden now shows, unminimizes and focuses the existing window instead of
  silently exiting.
- **Claude and Antigravity import from the same JSON.** One Cockpit/CPA or
  sub2api export can contain OpenAI, Anthropic and Antigravity entries. Codex
  accounts go to the vault; Claude and Antigravity credentials become engine
  auth files, and existing engine metadata (device ids, organization) is
  preserved.
- **Includes 3.2.0.** The sidebar button changes to a gold **Обновить** when a
  newer release exists, macOS shows a sidebar notice, Windows shows a toast,
  and both apps check hourly and on launch.
- **Build metadata.** macOS build 36; version metadata is aligned at 3.3.0.

> **Signing note:** these builds are ad-hoc signed (macOS) and unsigned
> (Windows). Verify every download against its `.sha256` file or `SHA256SUMS`.

### Downloads

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.3.0/MelonTools-3.3.0.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.3.0/MelonTools-3.3.0-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.3.0/MelonTools-3.3.0-win-x64-portable.exe)

### SHA-256

```
394c8dc6dbe7b4077fd37018baff1898864587d47b5ebffa54780abe424689be  MelonTools-3.3.0.dmg
20ec74f478a8537cd24076e05f5d493da356301e0fd9cc7d40979968af171bf2  MelonTools-3.3.0-setup.exe
c064aef4c6dc479395edef8761cd458fba0d33a345d70cdc518c2b5fd265cb99  MelonTools-3.3.0-win-x64-portable.exe
c064aef4c6dc479395edef8761cd458fba0d33a345d70cdc518c2b5fd265cb99  MelonTools-3.3.0-win-x64.exe
```

## 3.2.0
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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.2.0/MelonTools-3.2.0.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.2.0/MelonTools-3.2.0-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.2.0/MelonTools-3.2.0-win-x64-portable.exe)

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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.1.2/MelonTools-3.1.2.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.1.2/MelonTools-3.1.2-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.1.2/MelonTools-3.1.2-win-x64-portable.exe)

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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.1.1/MelonTools-3.1.1.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.1.1/MelonTools-3.1.1-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.1.1/MelonTools-3.1.1-win-x64-portable.exe)

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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.1.0/MelonTools-3.1.0.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.1.0/MelonTools-3.1.0-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.1.0/MelonTools-3.1.0-win-x64-portable.exe)

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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.0.1/MelonTools-3.0.1.dmg)
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.0.1/MelonTools-3.0.1-setup.exe)
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.0.1/MelonTools-3.0.1-win-x64-portable.exe)

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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v3.0.0/MelonTools-3.0.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v3.0.0/MelonTools-3.0.0-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v3.0.0/MelonTools-3.0.0-win-x64-portable.exe) — single file, no install.

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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v2.4.1/MelonTools-2.4.1.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v2.4.1/MelonTools-2.4.1-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v2.4.1/MelonTools-2.4.1-win-x64-portable.exe) — single file, no install.

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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v2.4.0/MelonTools-2.4.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v2.4.0/MelonTools-2.4.0-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v2.4.0/MelonTools-2.4.0-win-x64-portable.exe) — single file, no install.

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

- [macOS universal DMG](https://github.com/vanich-git/MelonTools/releases/download/v2.3.7/MelonTools-2.3.7.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/vanich-git/MelonTools/releases/download/v2.3.7/MelonTools-2.3.7-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/vanich-git/MelonTools/releases/download/v2.3.7/MelonTools-2.3.7-win-x64-portable.exe) — single file, no install.

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
