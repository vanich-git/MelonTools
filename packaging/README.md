# Packaging, signing, and distribution

This directory holds the release-signing scaffolding and the distribution
manifests for Melon Tools. The application source and version files are not
touched by the packaging scripts.

## Current status

**Signing and notarization are BLOCKED until real certificates are provided.**

| Platform | State | Consequence |
|----------|-------|-------------|
| macOS | Ad-hoc signed, not notarized | Gatekeeper may require right-click → Open on first launch. |
| Windows | Not Authenticode-signed | SmartScreen may warn on first launch. |

The CI release workflow builds and publishes unsigned artifacts when the
secrets below are absent. It never fails because a signing secret is missing.
When the secrets exist, the signing steps run and a genuine signing failure
does fail the release.

## Release artifacts for 5.5.5

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-5.5.5.dmg` | `920280ccdf2da27ccfc61818f7985cfef15ab48f9371be4be658f3d80e869a88` |
| Windows installer | `MelonTools-5.5.5-setup.exe` | `f13c05aa1e22d59acfce45eb997367d61702c7830529e2d95da3a36f9f8a68de` |
| Windows portable | `MelonTools-5.5.5-win-x64-portable.exe` | `eeaf9d42ffca809ecc1a5395ac05ae11aa49f7aa8f577087e6ad1d7031e86da0` |

5.5.5 adds the status island to macOS and Windows, fixes the side-by-side
layout on displays without a notch, and removes the background polling and
window-handling problems found in the audit.

All files and their `.sha256` siblings are attached to the GitHub release for
tag `v5.5.5`.

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

## Manifest bump order (prevents REL-1)

The Homebrew Cask and winget manifests must describe the artifacts that are
actually published. Never tag before this order is complete:

1. Build both platforms from the release commit (CI `package` jobs).
2. Copy the artifacts into one directory and run
   `python3 scripts/verify_release_checksums.py --artifacts DIR --write`.
3. Commit the resulting Cask/winget hash changes with the version bump.
4. Run `python3 scripts/verify_release_checksums.py --artifacts DIR --version X.Y.Z`
   and `python3 .github/scripts/docs_lint.py`; both must pass.
5. Tag the commit. The release workflow refuses to overwrite a published
   release and always creates a **draft** first; a human verifies the hashes
   and promotes it.

`scripts/verify_release_checksums.py` is stdlib-only and is also called by
`docs_lint` for the static manifest checks.

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
  "MacOS/build/MelonTools-4.0.1.dmg"
```

The script:

1. Requires `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`; otherwise it
   prints a `SIGNING SKIPPED — macOS` block and exits 0.
2. Finds the `Developer ID Application` identity in the keychain.
3. Signs the gateway sidecar and the app with hardened runtime and a trusted
   timestamp.
4. Re-creates the DMG from the signed app.
5. Submits the DMG with `notarytool --wait` and staples the ticket.

Set `REQUIRE_SIGNING=1` to turn a missing-secret skip into an error (useful in
a strict local release script). The workflow itself uses the secret condition
on the step, so a missing secret simply skips the step.

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

## Homebrew Cask

The manifest lives at
[`homebrew/Casks/melon-tools.rb`](homebrew/Casks/melon-tools.rb). It points at
the DMG for the matching GitHub release and carries the published 4.0.0 DMG
SHA-256.

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

When a new release is prepared, update all of these together:

1. `MacOS/app/project.yml` (macOS version — only the release owner changes it).
2. `Windows/app/src-tauri/Cargo.toml` (Windows version).
3. The Cask `version`, `url`, and `sha256`.
4. `PackageVersion` in all three winget manifests, plus `InstallerUrl` and
   `InstallerSha256` in the installer manifest.

`python3 .github/scripts/docs_lint.py` fails when these versions disagree or a
manifest loses its 64-character SHA-256.

## Checksums

```bash
shasum -a 256 MacOS/build/MelonTools-4.0.1.dmg
```

```powershell
Get-FileHash .\MelonTools-4.0.1-setup.exe -Algorithm SHA256
```

The `.sha256` files published next to each artifact use the standard
`<hex>  <file name>` format. The in-app updater reads the first 64-character
hex token, so both formats are accepted.
