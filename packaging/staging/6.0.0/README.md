# Release metadata staging for 6.0.0

Generated from real artifacts in `/home/runner/work/MelonTools/MelonTools/release-assets`. This directory is a **draft**:
the committed manifests still describe the last published release.

Do not publish or tag until a human has:

1. uploaded the matching artifacts to a **draft** GitHub release;
2. verified every hash below against the downloaded assets;
3. copied these files over the committed manifests
   (`homebrew/Casks/melon-tools.rb` and `winget/*.yaml`);
4. appended `PACKAGING_README.section.md` to `packaging/README.md` and updated
   the README "what's new" headings to 6.0.0;
5. run `python3 scripts/verify_release_checksums.py --version 6.0.0` and
   `python3 .github/scripts/docs_lint.py --release 6.0.0`;
6. reviewed `docs/RELEASE_ACCEPTANCE.md`.

If any artifact is rebuilt, regenerate this directory; never hand-edit a hash.

## SHA-256

```
3880cd300f4bd40b9be394583d9cbac0f5458aafcb9c9d9779755b5da4e01b25  MelonTools-6.0.0-setup.exe
f759514dc44383ce378d4d0ce652acecccaa566445a928efc64129e29d3b5b52  MelonTools-6.0.0-win-x64-portable.exe
f759514dc44383ce378d4d0ce652acecccaa566445a928efc64129e29d3b5b52  MelonTools-6.0.0-win-x64.exe
956f2105e974302383e66246dd67a8e57a004f1b8d49354a5733a61961d6dd77  MelonTools-6.0.0.dmg
```
