# Release metadata staging for 6.5.1

Generated from real artifacts in `/home/runner/work/MelonTools/MelonTools/release-assets`. This directory is a **draft**:
the committed manifests still describe the last published release.

Do not publish or tag until a human has:

1. uploaded the matching artifacts to a **draft** GitHub release;
2. verified every hash below against the downloaded assets;
3. copied these files over the committed manifests
   (`homebrew/Casks/melon-tools.rb` and `winget/*.yaml`);
4. appended `PACKAGING_README.section.md` to `packaging/README.md` and updated
   the README "what's new" headings to 6.5.1;
5. run `python3 scripts/verify_release_checksums.py --version 6.5.1` and
   `python3 .github/scripts/docs_lint.py --release 6.5.1`;
6. reviewed `docs/RELEASE_ACCEPTANCE.md`.

If any artifact is rebuilt, regenerate this directory; never hand-edit a hash.

## SHA-256

```
9b23c23626a7d0b437eb1f2bf8cfc41856e805533f927d6c31965b8d3d54ed12  MelonTools-6.5.1-setup.exe
1ee5ccd1f63c3a36d56ae9619b02202e1150c0eeeedeb877316d457021efdf5c  MelonTools-6.5.1-win-x64-portable.exe
1ee5ccd1f63c3a36d56ae9619b02202e1150c0eeeedeb877316d457021efdf5c  MelonTools-6.5.1-win-x64.exe
f2b92902fa375433f94a18d89a56ffcde0e067c9df935544f529bb6fbc968b7b  MelonTools-6.5.1.dmg
```
