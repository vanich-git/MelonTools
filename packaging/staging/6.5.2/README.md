# Release metadata staging for 6.5.2

Generated from real artifacts in `/home/runner/work/MelonTools/MelonTools/release-assets`. This directory is a **draft**:
the committed manifests still describe the last published release.

Do not publish or tag until a human has:

1. uploaded the matching artifacts to a **draft** GitHub release;
2. verified every hash below against the downloaded assets;
3. copied these files over the committed manifests
   (`homebrew/Casks/melon-tools.rb` and `winget/*.yaml`);
4. appended `PACKAGING_README.section.md` to `packaging/README.md` and updated
   the README "what's new" headings to 6.5.2;
5. run `python3 scripts/verify_release_checksums.py --version 6.5.2` and
   `python3 .github/scripts/docs_lint.py --release 6.5.2`;
6. reviewed `docs/RELEASE_ACCEPTANCE.md`.

If any artifact is rebuilt, regenerate this directory; never hand-edit a hash.

## SHA-256

```
d724d6d567e2ee520f863348e7800b0b8432f1df95529700151db6da9075c2b8  MelonTools-6.5.2-setup.exe
d3c6a67bb8745057a164ca767b1925af8d8259ca1e407e20322935d76eb31972  MelonTools-6.5.2-win-x64-portable.exe
d3c6a67bb8745057a164ca767b1925af8d8259ca1e407e20322935d76eb31972  MelonTools-6.5.2-win-x64.exe
eb4c3a027e1532cf51204be499bb19382a9c3ef307515538b9709888a246c501  MelonTools-6.5.2.dmg
```
