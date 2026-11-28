# Release metadata staging for 6.5.3

Generated from real artifacts in `/home/runner/work/MelonTools/MelonTools/release-assets`. This directory is a **draft**:
the committed manifests still describe the last published release.

Do not publish or tag until a human has:

1. uploaded the matching artifacts to a **draft** GitHub release;
2. verified every hash below against the downloaded assets;
3. copied these files over the committed manifests
   (`homebrew/Casks/melon-tools.rb` and `winget/*.yaml`);
4. appended `PACKAGING_README.section.md` to `packaging/README.md` and updated
   the README "what's new" headings to 6.5.3;
5. run `python3 scripts/verify_release_checksums.py --version 6.5.3` and
   `python3 .github/scripts/docs_lint.py --release 6.5.3`;
6. reviewed `docs/RELEASE_ACCEPTANCE.md`.

If any artifact is rebuilt, regenerate this directory; never hand-edit a hash.

## SHA-256

```
66bc815ddb485965d651692a7190d3840ce5794ea1999613d1acaccd10eee9f6  MelonTools-6.5.3-setup.exe
fc3eea0eb66dca340ca8fd5e4b6a483c67365485beef1dd1ed7c3f680c53d3c1  MelonTools-6.5.3-win-x64-portable.exe
fc3eea0eb66dca340ca8fd5e4b6a483c67365485beef1dd1ed7c3f680c53d3c1  MelonTools-6.5.3-win-x64.exe
df688ec660b6e26263a5856561a4826ed1f97deac133f42814ee24205f1a13f2  MelonTools-6.5.3.dmg
```
