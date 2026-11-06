# Packaging, signing, and distribution

This directory holds the release-signing scaffolding and the distribution
manifests for Melon Tools. The application source and version files are not
touched by the packaging scripts.

## Current status

The application source tree is **6.0.0-rc.4**, published as a GitHub
**prerelease**. The stable **6.0.0** promotion is still pending. The Homebrew
Cask and winget manifests below still describe the last published stable
release, 5.5.8, with its real hashes. That is deliberate: a prerelease is never
promoted into the stable manifests, and a version number is not evidence that
an artifact exists — inventing a SHA-256 would make every download check
meaningless.

**Signing and notarization are BLOCKED until real certificates are provided.**

| Platform | State | Consequence |
|----------|-------|-------------|
| macOS | Ad-hoc signed, not notarized | Gatekeeper may require right-click → Open on first launch. |
| Windows | Not Authenticode-signed | SmartScreen may warn on first launch. |

The CI release workflow builds and publishes unsigned artifacts when the
secrets below are absent. It never fails because a signing secret is missing.
When the secrets exist, the signing steps run and a genuine signing failure
does fail the release.

## 6.0.0-rc.4 (prerelease)

A prerelease ships through the draft → GitHub prerelease path only:

- `release.yml` builds both platforms, writes `prerelease: true` when the
  version contains `-`, and leaves the release as a **draft** for a human.
- Publishing the draft keeps it a prerelease: it never becomes "latest", so
  the in-app updaters (which read `/releases/latest`) ignore it.
- `release-promote.yml` and `docs_lint.py --release 6.0.0-rc.4` (without
  `--preflight`) refuse a prerelease on purpose: Homebrew and winget describe
  stable artifacts, and an RC must not reach `brew upgrade` or
  `winget upgrade`.

The pre-tag gate accepts a prerelease only in `--preflight` form:

```bash
python3 .github/scripts/docs_lint.py --release 6.0.0-rc.4 --preflight
```

Stable promotion is unchanged and applies to `6.0.0` only:

```bash
# release-promote.yml, after the promotion commit: the live manifests, the
# downloaded draft assets and the staged provenance must agree.
python3 .github/scripts/docs_lint.py --release 6.0.0
python3 scripts/verify_release_checksums.py \
  --artifacts draft-assets \
  --sha256sums draft-assets/SHA256SUMS \
  --version 6.0.0 \
  --require-provenance
```

`--stage` generates draft metadata from real build outputs; it refuses to run
when the DMG, NSIS setup, portable exe, or their `.sha256` siblings are
missing, and it never writes a placeholder digest. For a prerelease,
`--stage 6.0.0-rc.4` is used by `release.yml` to verify the uploaded draft
assets only — its output is not committed and never edits the manifests.
`docs_lint.py` without `--release` allows the application version to run ahead
of the published distribution metadata and prints a note. See
[`docs/RELEASE_ACCEPTANCE.md`](../docs/RELEASE_ACCEPTANCE.md) and
[`docs/AUDIT_WINDOWS_MACOS_2026-11-04.md`](../docs/AUDIT_WINDOWS_MACOS_2026-11-04.md)
(REL-03/REL-04).

## Release artifacts for 5.5.8

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-5.5.8.dmg` | `9567211bedb1b714bae44ad6d3df3fffb9271dbbc09d74275384575359b50bc4` |
| Windows installer | `MelonTools-5.5.8-setup.exe` | `653d1354543fc792fb7e61ffea25029ea5079550fbad338f82d190e2aaef69b6` |
| Windows portable | `MelonTools-5.5.8-win-x64-portable.exe` | `f1a03dc6bb432763bee5a455afec16c4bca0ebcb6f6cdc2adaac2da3e8da534a` |

5.5.8 makes Windows expansion reliable: the compact pill and the 420×242 card
are separate native windows, so showing the card never asks WebView2 to resize
a surface. The compact line shows the 5-hour total, weekly total, Codex account count and
API dot. The large card folds back after Immediately / 5 / 10 / 15 / 20 seconds
(default 15) and has an explicit × button.
The macOS build keeps the 5.5.6 silhouette at build 55.

All files and their `.sha256` siblings are attached to the GitHub release for
tag `v5.5.8`.

## Release artifacts for 5.0.0 (previous release)

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-5.0.0.dmg` | `436732a5117b56f451d0a65f79a68556f7fda18786596326c282dc5832ac58c4` |
| Windows installer | `MelonTools-5.0.0-setup.exe` | `6cf1a3ab6373962286591bc6f8681af90bf24385baad9c1c9a6fdeaad898cd01` |
| Windows portable | `MelonTools-5.0.0-win-x64-portable.exe` | `97b66b6da08058523d7d0b1160d505a79c02abc0525fbd69c96795ee454b4ea1` |

5.0.0 ships the redesign on both platforms: the macOS DMG and the Windows
installer/portable are built from the same tag and carry the same interface.

All files and their `.sha256` siblings are attached to the GitHub release for
tag `v5.0.0`.

## Release artifacts for 4.0.1 (previous macOS + Windows release)

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-4.0.1.dmg` | `aa3edd02d256613a8ddb919abd33a766b3026d7a36ac14890da90c2ca65af91a` |
| Windows installer | `MelonTools-4.0.1-setup.exe` | `5a3ab2fa8fc1ab493feaa3e29a7b58f5dfad69fbea5d38df3a9dd6ad7250bee3` |
| Windows portable | `MelonTools-4.0.1-win-x64-portable.exe` | `6c89e946196a74dac06a6e2e4fa03427ae234901cb8775d58a0b3ff3b6eb181e` |
| Windows legacy alias | `MelonTools-4.0.1-win-x64.exe` | `6c89e946196a74dac06a6e2e4fa03427ae234901cb8775d58a0b3ff3b6eb181e` |

All files and their `.sha256` siblings are attached to the GitHub release for
tag `v4.0.1`.

## Release artifacts for 4.0.0 (previous release)

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-4.0.0.dmg` | `3deb12c07d59f6bcf12bf0717d455bcb495713f31327ea01eec04eb2abb13220` |
| Windows installer | `MelonTools-4.0.0-setup.exe` | `f515ef6d0abb86690b070f1eb5b0f88532079ba5e7ba0fbb7d22851ce3f0ab1d` |
| Windows portable | `MelonTools-4.0.0-win-x64-portable.exe` | `6bba8457add3a0c347e3a39fca6c2a568f47f74108a318e79f01df4c2ba7bab8` |
| Windows legacy alias | `MelonTools-4.0.0-win-x64.exe` | `6bba8457add3a0c347e3a39fca6c2a568f47f74108a318e79f01df4c2ba7bab8` |

All files and their `.sha256` siblings are attached to the GitHub release for
tag `v4.0.0`. The in-app updater accepts only HTTPS GitHub hosts and verifies
the downloaded file against the release digest or the `.sha256` sibling.

The release workflow also publishes stable, unversioned aliases
(`MelonTools.dmg`, `MelonTools-setup.exe`, `MelonTools-win-x64-portable.exe`,
`MelonTools-win-x64.exe`) for the README "latest" links, plus one combined
`SHA256SUMS` file. Versioned files remain the auditable target for release
notes and backfills.

## Release artifacts for 3.4.2 (previous release)

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-3.4.2.dmg` | `624c90b7bd8a17fba827fc8e9c93405d749465478c9ef4bdce9dbcd48fc8db61` |
| Windows installer | `MelonTools-3.4.2-setup.exe` | `fa3a7fb206008bf584ec61303f25b89e89cac320a59fe0d9d3adbb21706d01e5` |
| Windows portable | `MelonTools-3.4.2-win-x64-portable.exe` | `f6e35fe81d77905b5b534f132f80f01e1770497f515d5c7c69868640237323df` |
| Windows legacy alias | `MelonTools-3.4.2-win-x64.exe` | `f6e35fe81d77905b5b534f132f80f01e1770497f515d5c7c69868640237323df` |

## Manifest bump order (prevents REL-1/REL-03)

The Homebrew Cask and winget manifests must describe the artifacts that are
actually published. The release has two phases because code signing and
notarization timestamp the binaries during the build: the real hashes cannot be
committed before the build, and the build must not publish unverified assets.

**Phase 1 — tag and build a draft.**

1. Finish the sources: `MacOS/RELEASE_NOTES.md` must describe X.Y.Z with no
   "draft release notes" marker, and the app/crate versions must be X.Y.Z.
   `python3 .github/scripts/docs_lint.py --release X.Y.Z --preflight` must pass.
   Homebrew/winget still describe the previously published version here; that
   is expected and is not relaxed at promotion.
2. Tag the commit. `release.yml` builds both platforms, runs
   `verify_release_checksums.py --stage` on the real artifacts, and requires the
   built assets to match that metadata byte for byte
   (`--verify-staged`). It creates a **draft** release with a
   `MelonTools-X.Y.Z-release-metadata.zip` attachment and never publishes.
3. A human downloads the draft assets, recomputes the hashes, and reviews the
   staged Cask/winget files inside the zip.

**Phase 2 — promote the manifests, then publish.**

4. Extract the attached `release-metadata/` into `packaging/staging/X.Y.Z/`,
   copy its Cask/winget files over the committed manifests, append
   `PACKAGING_README.section.md` to this file, and update the "what's new"
   headings in `README.md`, `README.ru.md` and `MacOS/README.md` to X.Y.Z.
   Commit that promotion.
5. Run the `Release promotion` workflow (`release-promote.yml`) with the tag.
   It refuses to continue unless:
   - the live Cask/winget hashes equal `packaging/staging/X.Y.Z/`
     (`--require-provenance`);
   - the downloaded draft assets equal the live manifests and `SHA256SUMS`;
   - the attached metadata zip is byte-identical to `packaging/staging/X.Y.Z/`;
   - `docs_lint.py --release X.Y.Z` passes.
   Only then does it undraft the release (and it never re-promotes an already
   published tag).

`--write` remains a low-level local helper; it does not create a draft or a
release gate.

`scripts/verify_release_checksums.py` is stdlib-only and is also called by
`docs_lint` for the static manifest checks. `--write` remains available as a
low-level helper, but it does not create a draft directory or a release gate.

## Signing secrets and repository settings

Create a GitHub **environment named `release`** and restrict it to release
maintainers; the macOS, Windows, and publish jobs use it. Required repository
settings (cannot be set from this repo):

- tag protection for `v*` (only maintainers may create/delete release tags);
- branch protection on `main` requiring CI, CodeQL, and docs-lint;
- environment `release` with required reviewers and deployment branches/tags;
- `contents: write` only on the publish job (already scoped per job).

The signing secrets are exposed only to the specific import/sign steps, not to
every step of a job, and are never passed as command-line arguments.

## Release artifacts for 3.4.1 (previous release)

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-3.4.1.dmg` | `fe3e9956dd067de43cbabc08375f2495fca823a533792cb464a13f2ff35b8677` |
| Windows installer | `MelonTools-3.4.1-setup.exe` | `72b42da27e0689ea1d436aa635cc6847e12e8707e9509ef9b48767d561c36d75` |
| Windows portable | `MelonTools-3.4.1-win-x64-portable.exe` | `ac035405a320b3ee0690b7627a28dece7050f6f497bc92ddda68e9ce19f4ab6a` |
| Windows legacy alias | `MelonTools-3.4.1-win-x64.exe` | `ac035405a320b3ee0690b7627a28dece7050f6f497bc92ddda68e9ce19f4ab6a` |

## Required secrets

Configure these in **Settings → Secrets and variables → Actions**.

### macOS

| Secret | Required | Purpose |
|--------|----------|---------|
| `APPLE_CERT_P12` | yes | Base64 of a `.p12` containing a **Developer ID Application** certificate and its private key. |
| `APPLE_CERT_PASSWORD` | yes | Password that protects the `.p12`. |
| `APPLE_ID` | yes | Apple developer account email used by `notarytool`. |
| `APPLE_TEAM_ID` | yes | Apple Developer team identifier. |
| `APPLE_APP_PASSWORD` | yes | App-specific password for `notarytool`. |
| `APPLE_SIGN_IDENTITY` | no | Exact codesign identity. Defaults to the first `Developer ID Application` identity in the keychain. |

### Windows

| Secret | Required | Purpose |
|--------|----------|---------|
| `WINDOWS_CERT_PFX` | yes | Base64 of an Authenticode `.pfx` (OV or EV code-signing certificate). |
| `WINDOWS_CERT_PASSWORD` | yes | Password that protects the `.pfx`. |

Create the base64 values locally:

```bash
# macOS / Linux
base64 -i certificate.p12 | pbcopy          # macOS
base64 -w 0 certificate.p12 > certificate.b64   # Linux
```

```powershell
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("certificate.pfx")) |
  Set-Clipboard
```

Never commit a certificate, password, or `.p12`/`.pfx` file. The repository
ignores build outputs, but it cannot protect a secret that was committed once.

## macOS signing and notarization

`.github/workflows/release.yml` imports `APPLE_CERT_P12` into a temporary
keychain, then calls:

```bash
./packaging/sign-macos.sh \
  "$HOME/Library/Developer/MelonTools/Build/Products/Release/MelonTools.app" \
  "MacOS/build/MelonTools-6.0.0.dmg"
```

The script:

1. Requires `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`; otherwise it
   prints a `SIGNING SKIPPED — macOS` block and exits 0.
2. Finds the `Developer ID Application` identity in the keychain.
3. Signs every nested Mach-O file, including
   `Contents/Resources/runtime/llama-server` and its dylibs; ad-hoc signatures
   from `fetch-runtime.sh` are replaced before the outer bundle is sealed.
4. Recomputes `runtime.sha256`/`runtime.json` from the **signed** runtime bytes
   via `fetch-runtime.sh --refresh-manifest`, then verifies it with
   `fetch-runtime.sh --check`.
5. Signs the app with hardened runtime and a trusted timestamp, verifies deep
   strict signatures, and rejects any nested code that is not Developer ID
   signed.
6. Re-creates the DMG from the signed app and checks the runtime manifest again
   in the staged bundle.
7. Submits the DMG with `notarytool --wait`, fails unless the result is
   `status: Accepted`, staples the ticket, and validates it.

Set `REQUIRE_SIGNING=1` to turn a missing-secret skip into an error (useful in
a strict local release script). The workflow itself uses the secret condition
on the step, so a missing secret simply skips the step. After signing, run
`MacOS/scripts/native-acceptance.sh --dmg <file> --require-signed` and complete
[`docs/RELEASE_ACCEPTANCE.md`](../docs/RELEASE_ACCEPTANCE.md).

## Windows signing

`.github/workflows/release.yml` decodes `WINDOWS_CERT_PFX` to a temporary file
and calls:

```powershell
./packaging/sign-windows.ps1 `
  -File Windows/dist/MelonTools-4.0.1-setup.exe -Require
```

The script locates `signtool.exe` from the Windows SDK, signs with SHA-256 and
an RFC 3161 timestamp, and verifies the result. Without the two certificate
variables it prints `SIGNING SKIPPED - Windows` and exits 0; `-Require` turns
that skip into an error.

The release and package jobs also run
`packaging/verify-windows-artifacts.ps1 -Dist Windows/dist -Version X.Y.Z`
(add `-RequireSignature` when a certificate exists). It checks PE x64/NSIS
structure, the `.sha256` siblings, the legacy alias equality and Authenticode.
It does not install or launch the app; those checks stay in
[`docs/RELEASE_ACCEPTANCE.md`](../docs/RELEASE_ACCEPTANCE.md).

## Homebrew Cask

The manifest lives at
[`homebrew/Casks/melon-tools.rb`](homebrew/Casks/melon-tools.rb). It points at
the DMG for the matching GitHub release and currently carries the published
5.5.8 DMG SHA-256. Do not change it to 6.0.0 until the stable 6.0.0 artifacts
are built, acceptance-checked and promoted; the 6.0.0-rc.4 prerelease is never
promoted into this manifest.

Local validation and installation:

```bash
ruby -c packaging/homebrew/Casks/melon-tools.rb
brew audit --cask --strict packaging/homebrew/Casks/melon-tools.rb
brew install --cask packaging/homebrew/Casks/melon-tools.rb
```

The cask is not yet submitted to the upstream `homebrew-cask` repository. A
future submission requires a notarized DMG; the Cask cannot pass upstream audit
while the build is ad-hoc signed. This is part of the signing blocker.

## winget manifests

The three manifests live in [`winget/`](winget/):

- `vanich-git.MelonTools.yaml` — version manifest
- `vanich-git.MelonTools.installer.yaml` — portable x64 exe, URL, SHA-256
- `vanich-git.MelonTools.locale.en-US.yaml` — display metadata

Local validation on Windows:

```powershell
winget validate packaging/winget
```

The manifests target a future `winget-pkgs` submission but are not submitted
yet. Upstream validation expects a stable, signed release; the unsigned exe can
still be installed manually from the GitHub release.

## Version bumps

When a new release is prepared, update the application versions together:

1. `MacOS/app/project.yml` (macOS version — only the release owner changes it).
2. `Windows/app/src-tauri/Cargo.toml` and the lock file (Windows version).
3. `MacOS/RELEASE_NOTES.md` top heading.

Do **not** hand-edit the Cask/winget `version`, URL, or SHA-256. Build the
artifacts and run `--stage`; the generated files carry the matching version and
the real hashes. `docs_lint.py` without `--release` tolerates an unreleased
application version in front of the published distribution metadata and prints
a note; `docs_lint.py --release X.Y.Z` requires the promoted manifests, the
generated `RELEASE_METADATA.json`/`SHA256SUMS` provenance, and updated README
headings. It also fails when a live manifest loses its 64-character SHA-256.

## Checksums

```bash
shasum -a 256 MacOS/build/MelonTools-X.Y.Z.dmg
```

```powershell
Get-FileHash .\MelonTools-4.0.1-setup.exe -Algorithm SHA256
```

The `.sha256` files published next to each artifact use the standard
`<hex>  <file name>` format. The in-app updater reads the first 64-character
hex token, so both formats are accepted.
