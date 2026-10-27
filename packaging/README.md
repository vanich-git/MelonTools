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

## Release artifacts for 2.4.2

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-2.4.2.dmg` | `3b50911275c36a3bdf5f8af60d6f1c7be04a21cc1a70702785409be44a54ec00` |
| Windows installer | `MelonTools-2.4.2-setup.exe` | `95ecabf61ab9b5d4af1b8d980f4c97ac3e5b3bbae9cd65238fe6eb6d168e3a71` |
| Windows portable | `MelonTools-2.4.2-win-x64-portable.exe` | `608fc98e8c0aa74f75f772b8d028b2c553f2f2a088c00e2afca9b271da18a112` |
| Windows legacy alias | `MelonTools-2.4.2-win-x64.exe` | `608fc98e8c0aa74f75f772b8d028b2c553f2f2a088c00e2afca9b271da18a112` |

All files and their `.sha256` siblings are attached to the GitHub release for
tag `v2.4.2`. The in-app updater accepts only HTTPS GitHub hosts and verifies
the downloaded file against the release digest or the `.sha256` sibling.

The release workflow also publishes stable, unversioned aliases
(`MelonTools.dmg`, `MelonTools-setup.exe`, `MelonTools-win-x64-portable.exe`,
`MelonTools-win-x64.exe`) for the README "latest" links, plus one combined
`SHA256SUMS` file. Versioned files remain the auditable target for release
notes and backfills.

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

## Release artifacts for 2.3.7 (previous release)

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-2.3.7.dmg` | `3415474dfa107fdfaaf3c6d9eb356df862b49aa9d6694a236a56b68ebb7f17a6` |
| Windows installer | `MelonTools-2.3.7-setup.exe` | `d7d73ce0d3cd53f360149cf21c14968cd461b76d842fc48deecbe54702fc83b3` |
| Windows portable | `MelonTools-2.3.7-win-x64-portable.exe` | `a93e3edb197d3a9309d600f5775d68a7d75503e4b9a314142b77ee7fb8d21f60` |
| Windows legacy alias | `MelonTools-2.3.7-win-x64.exe` | `a93e3edb197d3a9309d600f5775d68a7d75503e4b9a314142b77ee7fb8d21f60` |

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
  "MacOS/build/MelonTools-2.4.2.dmg"
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
  -File Windows/dist/MelonTools-2.4.2-setup.exe -Require
```

The script locates `signtool.exe` from the Windows SDK, signs with SHA-256 and
an RFC 3161 timestamp, and verifies the result. Without the two certificate
variables it prints `SIGNING SKIPPED - Windows` and exits 0; `-Require` turns
that skip into an error.

## Homebrew Cask

The manifest lives at
[`homebrew/Casks/melon-tools.rb`](homebrew/Casks/melon-tools.rb). It points at
the DMG for the matching GitHub release and carries the published 2.4.2 DMG
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

- `ivankuprin.MelonTools.yaml` — version manifest
- `ivankuprin.MelonTools.installer.yaml` — portable x64 exe, URL, SHA-256
- `ivankuprin.MelonTools.locale.en-US.yaml` — display metadata

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
shasum -a 256 MacOS/build/MelonTools-2.4.2.dmg
```

```powershell
Get-FileHash .\MelonTools-2.4.2-setup.exe -Algorithm SHA256
```

The `.sha256` files published next to each artifact use the standard
`<hex>  <file name>` format. The in-app updater reads the first 64-character
hex token, so both formats are accepted.
