# Release metadata staging

This directory holds **draft** Homebrew/winget metadata generated from real
built artifacts. It is not published and it is not a source of truth.

`packaging/staging/6.0.0/` currently contains only a placeholder README for the
**stable** 6.0.0 promotion: the source tree is 6.0.0-rc.1, which ships as a
GitHub prerelease and is never promoted. No stable 6.0.0 artifacts have been
built, verified and published, so the directory holds no Cask, winget manifest,
`SHA256SUMS`, or digest. Do not create generated files by hand
and do not put a placeholder SHA-256 in them. `docs_lint.py` rejects staged
digests that are not real 64-hex values, and
`verify_release_checksums.py --stage` refuses to run without the complete
artifact set and its `.sha256` siblings.

Generate it after both platforms are built from the release commit:

```bash
python3 scripts/verify_release_checksums.py \
  --stage 6.0.0 \
  --artifacts /path/to/release-assets
```

For a prerelease the same command takes `--stage 6.0.0-rc.1`. That output is
uploaded with the draft and used by `--verify-staged`; do not copy it into this
directory or into the committed manifests.

The script writes `homebrew/`, `winget/`, `SHA256SUMS`, `RELEASE_METADATA.json`,
`PACKAGING_README.section.md`, and a `README.md` with the exact hashes. In CI, `release.yml` runs `--stage` on the real build outputs, blocks unless
the built assets match it (`--verify-staged`), and attaches the directory to the
**draft** release. After a human reviews that draft, extract the attached
`release-metadata/` here, copy the Cask/winget files over the committed
manifests, and run the `Release promotion` workflow. Keep
`RELEASE_METADATA.json` and `SHA256SUMS` in the promoted staging directory: the
strict `docs_lint.py --release` gate and the promotion workflow require them to
prove the live hashes were generated from artifacts rather than typed by hand.
See `packaging/README.md` and `docs/RELEASE_ACCEPTANCE.md`.
