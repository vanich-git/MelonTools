# 6.0.0 staging — not generated

Status: **no stable 6.0.0 release artifacts exist in this checkout**. The source
tree is `6.0.0-rc.2`, which ships as a GitHub prerelease and is never promoted
into Homebrew or winget; the last published distribution is 5.5.8. Therefore
this directory contains no Cask, winget manifest, `SHA256SUMS`, or digest.

Do not create placeholder hashes here. Run the generator only against a
complete set of stable artifacts built from the release commit:

```bash
python3 scripts/verify_release_checksums.py \
  --stage 6.0.0 \
  --artifacts /path/to/release-assets
```

Required files (each with a `.sha256` sibling):

- `MelonTools-6.0.0.dmg`
- `MelonTools-6.0.0-setup.exe`
- `MelonTools-6.0.0-win-x64-portable.exe`
- `MelonTools-6.0.0-win-x64.exe` (legacy alias, byte-identical to portable)

Until then, `docs_lint.py` reports 6.0.0 as unreleased while Homebrew/winget
describe the published 5.5.8. `docs_lint.py --release 6.0.0` fails by design
because this directory has no `RELEASE_METADATA.json`, `SHA256SUMS`, Cask, or
winget manifest generated from real artifacts. When the generator runs it
replaces this README with promotion instructions. See `packaging/README.md`
and `docs/RELEASE_ACCEPTANCE.md`.
