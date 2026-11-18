# Release metadata staging for 6.0.2

Generated from real artifacts in `/home/runner/work/MelonTools/MelonTools/release-assets`. This directory is a **draft**:
the committed manifests still describe the last published release.

Do not publish or tag until a human has:

1. uploaded the matching artifacts to a **draft** GitHub release;
2. verified every hash below against the downloaded assets;
3. copied these files over the committed manifests
   (`homebrew/Casks/melon-tools.rb` and `winget/*.yaml`);
4. appended `PACKAGING_README.section.md` to `packaging/README.md` and updated
   the README "what's new" headings to 6.0.2;
5. run `python3 scripts/verify_release_checksums.py --version 6.0.2` and
   `python3 .github/scripts/docs_lint.py --release 6.0.2`;
6. reviewed `docs/RELEASE_ACCEPTANCE.md`.

If any artifact is rebuilt, regenerate this directory; never hand-edit a hash.

## SHA-256

```
d1520c7b685f8404a87d60a744891ee968d79d248e7efde53de0e5c2773a0940  MelonTools-6.0.2-setup.exe
60ea768ceec309e0ae506f79a8ca07e3141153019df61cfb4ad4efccad5c7c50  MelonTools-6.0.2-win-x64-portable.exe
60ea768ceec309e0ae506f79a8ca07e3141153019df61cfb4ad4efccad5c7c50  MelonTools-6.0.2-win-x64.exe
ce272579c3c18aadf2afee9baf2d73daafea34b590f03f9e6151fb182c49d413  MelonTools-6.0.2.dmg
```
