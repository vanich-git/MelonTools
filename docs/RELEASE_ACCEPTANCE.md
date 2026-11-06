# Release acceptance — Melon Tools 6.0.0

This plan targets the **stable 6.0.0** promotion. The 6.0.0-rc.4 prerelease is
published after the automated checks only (CI build on both platforms, docs
lint `--release 6.0.0-rc.4 --preflight`, artifact/checksum verification); every
manual row below stays open until stable 6.0.0 is promoted.

This checklist is the release gate for the Windows/macOS audit
([`AUDIT_WINDOWS_MACOS_2026-11-04.md`](AUDIT_WINDOWS_MACOS_2026-11-04.md)).
It separates checks that can run natively and automatically from checks that
still require a person and a real machine. A Chromium/mock smoke, an unsigned
local DMG, or a script that only reads source code is **not** native evidence.

## Status vocabulary

| Status | Meaning |
|---|---|
| `PASS` | The command ran on the stated host and the expected result was observed. |
| `FAIL` | The command ran and the expected result was not observed. A release blocker. |
| `SKIP` | The check could not run (unsigned build, missing host, missing certificate). Not a pass. |
| `MANUAL` | A human must perform the scenario and attach evidence. Not a pass until signed off. |

Every release sign-off records: build commit/tag, artifact SHA-256, macOS and
Windows versions, hardware (Apple Silicon / Intel), tester, date, and the
report paths. Never attach credentials, tokens, or personal data as evidence.

## 1. Automated native checks

### 1.1 Clean checkout and runtime ordering (REL-01)

```bash
# Run from a clean checkout; the script copies the tree without ignored files.
RUNTIME_CACHE="$PWD/MacOS/build/runtime-cache" \
  MacOS/scripts/test-clean-checkout.sh
```

Expected: the fixture has no `MacOS/app/Resources/runtime`; `xcodegen generate`
fails before the fetch; `fetch-runtime.sh` builds/verifies the pinned runtime;
the second `xcodegen generate` succeeds. CI runs the same fetch before its first
`xcodegen generate` (`.github/workflows/ci.yml`, `release.yml`).

```bash
MacOS/scripts/test-fetch-runtime.sh --quick   # bundled runtime only
MacOS/scripts/test-fetch-runtime.sh           # full sandbox rebuild
```

### 1.2 macOS artifact / signature / runtime manifest (REL-04)

```bash
MacOS/scripts/native-acceptance.sh \
  --dmg MacOS/build/MelonTools-6.0.0.dmg \
  --report /tmp/melon-native-acceptance.txt
```

Checks that run without Apple secrets: DMG structure and mount, bundle and
Info.plist version, deep-strict signature, every nested Mach-O signature,
universal runtime + `runtime.json` digest, embedded gateway gzip/digest, and
the DMG `.sha256` sibling when present.

With Developer ID secrets the release job runs the same script with
`--require-signed`; that additionally requires a non-ad-hoc signature, a
Developer ID authority on every nested Mach-O, Gatekeeper `spctl` acceptance,
and a stapled ticket where applicable. A skipped notarization check is **not** a
signed release pass.

### 1.3 Windows artifacts

On a Windows host:

```powershell
powershell -File packaging/verify-windows-artifacts.ps1 `
  -Dist Windows/dist -Version 6.0.0 -RequireSignature `
  -Report acceptance-windows.txt
```

Without a certificate, omit `-RequireSignature`; the Authenticode check is then
reported as `SKIP` and the release remains unsigned. The script checks PE x64,
the `.sha256` siblings, the legacy alias equality, and (when signed) Authenticode.
It does not install or launch the app.

### 1.4 Metadata and CI gates (REL-03)

```bash
python3 .github/scripts/docs_lint.py
python3 scripts/verify_release_checksums.py
python3 scripts/verify_release_checksums.py --version 6.0.0
bash -n MacOS/build.sh MacOS/scripts/*.sh packaging/sign-macos.sh
shellcheck -S warning MacOS/build.sh packaging/sign-macos.sh MacOS/scripts/*.sh
```

The release gates run in two phases; both are blocking.

**Phase 1, before tagging** — sources only:

```bash
python3 .github/scripts/docs_lint.py --release 6.0.0 --preflight
```

This requires the app/crate versions and `MacOS/RELEASE_NOTES.md` to describe
6.0.0 with no draft marker. It deliberately does not require Homebrew/winget to
be promoted: code signing and notarization timestamp the binaries during the
build, so the real hashes cannot exist before it.

**Phase 2, before publishing** — after `release.yml` created the draft:

```bash
python3 scripts/test_release_checksums.py          # gate regression suite
python3 scripts/verify_release_checksums.py --verify-staged <staged-dir> --artifacts <dir>
# after promoting packaging/staging/6.0.0/ and committing the manifests:
python3 .github/scripts/docs_lint.py --release 6.0.0
python3 scripts/verify_release_checksums.py --artifacts <draft-dir> \
  --sha256sums <draft-dir>/SHA256SUMS --version 6.0.0 --require-provenance
```

The `Release promotion` workflow runs those promotion steps on the downloaded
draft and only then undrafts it. `docs_lint.py` without `--release` may pass
while Homebrew/winget still describe the last published release; that is an
unreleased-state note, not a 6.0.0 release pass. The strict `--release 6.0.0`
fails on stale manifests, a draft marker, or missing/mismatched generated
provenance (`RELEASE_METADATA.json`, `SHA256SUMS`).

## 2. Manual macOS matrix

Use a clean macOS 14+ machine or VM. After installing from a DMG, detach the
volume (`hdiutil detach /Volumes/Melon\ Tools`) so LaunchServices does not keep
a second app copy.

| ID | Scenario | Steps | Expected | Evidence |
|---|---|---|---|---|
| MAC-01 | Clean install | Mount DMG, drag app to `/Applications`, detach, launch. | App starts; no crash report; `codesign --verify --deep --strict` passes; runtime extracted/verified. | Screenshot + console log |
| MAC-02 | Gatekeeper (unsigned) | First launch from a quarantined download. | Clear right-click → Open flow; no silent failure. | Screenshot |
| MAC-03 | Upgrade with active model | Install 5.5.8, start a local model, upgrade to 6.0.0, quit/relaunch. | Accounts/settings/tasks preserved; model registry migrated; no orphan `llama-server`; gateway routes rebuilt. | `ps`/`lsof` before/after, app log |
| MAC-04 | Rollback | Quit 6.0.0, reinstall 5.5.8, launch. | No destructive migration; data readable or clearly quarantined; no crash loop. | Data diff + log |
| MAC-05 | Signed/notarized DMG | On a clean Mac, download the signed DMG, verify SHA-256, mount, launch. | Gatekeeper accepts; `spctl --assess` passes; staple valid; no quarantine bypass needed. | `spctl`, `stapler`, screenshot |
| MAC-06 | Download pause/resume | Start a large GGUF download, pause, quit the app, relaunch, resume. | Existing `.part`/sidecar reused; no duplicate full download; progress visible after restart. | Network/storage diff |
| MAC-07 | Interrupted download | Kill the app/network mid-download; relaunch. | Partial file not published as installed; resume or clean retry; no registry entry without bytes. | Files + UI |
| MAC-08 | Full disk / read-only / detached storage | Fill the target volume; move the model directory to an external volume and detach it. | Clear error; no partial publish; registry stays consistent; app remains usable. | Screenshot + log |
| MAC-09 | Corrupt / newer registry | Corrupt `models.json`; separately write a newer schema version. | Corrupt file backed up/quarantined; visible error; no silent empty overwrite; newer schema not downgraded. | Backup file + screenshot |
| MAC-10 | Sleep/wake/logoff | Sleep during generation; wake; log out/in. | Process/route state normalized; no false Ready; no orphan engine; downloads resume safely. | `ps`/`lsof`, app log |
| MAC-11 | Tray/menu-bar soak | Run in the menu bar for at least 2 hours with scheduler enabled. | Bounded CPU/RAM; no growing `llama-server` log; no duplicate engines; quit leaves no child. | Activity Monitor, `ps` |
| MAC-12 | Native UI | Keyboard-only navigation, focus order, dialogs, VoiceOver labels; 125/150/200% scaling if available. | No unreachable control; dialogs dismiss correctly; labels are meaningful. | Screen recording/notes |

## 3. Manual Windows matrix

Run on a real Windows 10 1809+/Windows 11 x64 machine or VM with WebView2.

| ID | Scenario | Steps | Expected | Evidence |
|---|---|---|---|---|
| WIN-01 | Clean install | Run the NSIS installer as a normal user; launch; uninstall. | Installer completes; app starts; uninstall removes program files but preserves user data as documented. | Screenshots |
| WIN-02 | Portable | Run the portable exe from a writable folder. | Starts without install; data in `%APPDATA%\MelonTools`. | Screenshot |
| WIN-03 | Upgrade with active model | Start a local model on 5.5.8, upgrade to 6.0.0, relaunch. | No orphan `llama-server`/port; registry/routes rebuilt; data preserved. | Task Manager, logs |
| WIN-04 | WebView2 IPC | Exercise every redesigned page/action, including dialogs and keyboard focus. | No rejected IPC; no blank panel; commands reach Rust handlers. | Screen recording + console |
| WIN-05 | DPAPI migration | Open 5.5.8 data with plaintext/`dpapi:` tokens, save, restart. | Tokens migrate to `dpapi2:`; no re-login unless required; no plaintext leak. | Sanitized JSON keys only |
| WIN-06 | DPI | 125/150/200% scaling, multi-monitor, island on secondary display. | No clipped controls; island stays on-screen; no resize loop. | Screenshots |
| WIN-07 | Tray/background | Minimize to tray, sleep/wake, logoff, long soak. | Scheduler keeps running; no duplicate windows; quit stops engines. | Task Manager |
| WIN-08 | Authenticode | If a certificate exists, verify the installer and portable exe. | `Get-AuthenticodeSignature` is `Valid`; SmartScreen recognises the publisher. | PowerShell output |

## 4. Sign-off record

| Gate | Required evidence | Status |
|---|---|---|
| REL-01 clean checkout/runtime | `test-clean-checkout.sh` report + CI green | |
| REL-03 metadata | `--verify-staged` build gate + promotion workflow: draft assets, promoted manifests, `docs_lint --release` | |
| REL-04 signing | `sign-macos.sh` output, TeamIdentifier, `spctl`, staple, clean-Mac launch | |
| CORE-01..13 regression | Tests listed in the audit + targeted scenarios above | |
| Native macOS | MAC-01..12 (at least clean install, upgrade/rollback, signed DMG) | |
| Native Windows | WIN-01..08 (at least clean install, upgrade, WebView2) | |
| Artifact hashes | `SHA256SUMS` matches every attached asset | |

Release is blocked if any `FAIL` remains, if a required native row is `MANUAL`,
or if the artifact hashes were not generated from the published files.
