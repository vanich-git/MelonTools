# Release metadata staging for 6.0.1

Generated from real artifacts in `/home/runner/work/MelonTools/MelonTools/release-assets`. This directory is a **draft**:
the committed manifests still describe the last published release.

Do not publish or tag until a human has:

1. uploaded the matching artifacts to a **draft** GitHub release;
2. verified every hash below against the downloaded assets;
3. copied these files over the committed manifests
   (`homebrew/Casks/melon-tools.rb` and `winget/*.yaml`);
4. appended `PACKAGING_README.section.md` to `packaging/README.md` and updated
   the README "what's new" headings to 6.0.1;
5. run `python3 scripts/verify_release_checksums.py --version 6.0.1` and
   `python3 .github/scripts/docs_lint.py --release 6.0.1`;
6. reviewed `docs/RELEASE_ACCEPTANCE.md`.

If any artifact is rebuilt, regenerate this directory; never hand-edit a hash.

## SHA-256

```
d9edfc4b4d3f89839f796f1bdbde3bcf772131f3ca225d6cbb683d25312d7a9f  MelonTools-6.0.1-setup.exe
d118482a8435525f63bc7eef51436acf94242d85aff7c6b513c6f70c39603d74  MelonTools-6.0.1-win-x64-portable.exe
d118482a8435525f63bc7eef51436acf94242d85aff7c6b513c6f70c39603d74  MelonTools-6.0.1-win-x64.exe
2568c9c0178fe6bc7bfa875760111f00fe69de5b97447a5b3ef895f3dc3ab259  MelonTools-6.0.1.dmg
```
