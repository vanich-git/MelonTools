#!/usr/bin/env python3
"""Verify that the release manifests tell the truth about real artifacts.

The script is intentionally standard-library only. It compares:

* the Homebrew Cask ``version`` and ``sha256``;
* the three winget manifests (version, installer URL and ``InstallerSha256``);
* built artifacts (``--artifacts DIR``) and/or a ``SHA256SUMS`` file;
* the ``.sha256`` siblings that are published next to the artifacts.

Default behaviour is strict: any mismatch, missing file, wrong version or a
malformed digest exits with status 1. Use ``--warn-only`` in a rebuild job
where bit-for-bit reproducibility is not guaranteed; the report is still
printed and annotated.

Examples
--------

Verify a published download directory::

    python3 scripts/verify_release_checksums.py \
        --artifacts ~/Downloads/MelonTools-2.4.0 --version 2.4.0

Verify only the two manifests against a published checksum list::

    python3 scripts/verify_release_checksums.py --sha256sums SHA256SUMS

Regenerate the manifest hashes from a build (the release owner commits the
result before tagging)::

    python3 scripts/verify_release_checksums.py --artifacts MacOS/build --write

Generate a reviewable draft for a version that has no committed hashes yet::

    python3 scripts/verify_release_checksums.py \
        --stage 6.0.0 --artifacts release-assets

Verify the built artifacts against that draft before the release is published::

    python3 scripts/verify_release_checksums.py \
        --verify-staged packaging/staging/6.0.0 --artifacts release-assets
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional

ROOT = Path(__file__).resolve().parents[1]

CASK_PATH = ROOT / "packaging/homebrew/Casks/melon-tools.rb"
WINGET_INSTALLER = ROOT / "packaging/winget/vanich-git.MelonTools.installer.yaml"
WINGET_VERSION = ROOT / "packaging/winget/vanich-git.MelonTools.yaml"
WINGET_LOCALE = ROOT / "packaging/winget/vanich-git.MelonTools.locale.en-US.yaml"

HEX64 = re.compile(r"(?m)^[0-9a-fA-F]{64}\b")
SUMS_LINE = re.compile(r"^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$")
# MAJOR.MINOR.PATCH, optionally followed by -PRERELEASE (for example 6.0.0-rc.1).
SEMVER = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$")


class Report:
    def __init__(self, warn_only: bool = False) -> None:
        self.warn_only = warn_only
        self.errors: List[str] = []
        self.warnings: List[str] = []
        self.notes: List[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)

    def note(self, message: str) -> None:
        self.notes.append(message)

    def finish(self) -> int:
        for note in self.notes:
            print(f"  note: {note}")
        for warning in self.warnings:
            print(f"  warning: {warning}")
        if self.errors:
            label = "WARN (--warn-only)" if self.warn_only else "FAILED"
            print(f"release-checksums: {label}")
            for error in self.errors:
                print(f"  - {error}")
            return 0 if self.warn_only else 1
        print("release-checksums: OK")
        return 0


def read_text(path: Path, report: Report) -> str:
    if not path.is_file():
        report.error(f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}: missing")
        return ""
    return path.read_text(encoding="utf-8")


def search(pattern: str, text: str) -> Optional[str]:
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1) if match else None


def parse_cask(text: str) -> Dict[str, Optional[str]]:
    return {
        "version": re.search(r'^\s*version\s+"([^"]+)"', text, re.MULTILINE).group(1)
        if re.search(r'^\s*version\s+"([^"]+)"', text, re.MULTILINE)
        else None,
        "sha256": search(r'^\s*sha256\s+"([0-9a-fA-F]{64})"', text),
        "url": search(r'^\s*url\s+"([^"]+)"', text),
    }


def parse_winget_installer(text: str) -> Dict[str, Optional[str]]:
    return {
        "version": search(r"^PackageVersion:\s*(\S+)\s*$", text),
        "sha256": search(r"^\s*InstallerSha256:\s*([0-9a-fA-F]{64})\s*$", text),
        "url": search(r"^\s*InstallerUrl:\s*(\S+)\s*$", text),
    }


def parse_winget_version(text: str) -> Optional[str]:
    return search(r"^PackageVersion:\s*(\S+)\s*$", text)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_sums(path: Path, report: Report) -> Dict[str, str]:
    entries: Dict[str, str] = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = SUMS_LINE.match(line)
        if not match:
            report.error(f"{path}: line {number} is not '<sha256>  <file>'")
            continue
        name = Path(match.group(2)).name
        digest = match.group(1).lower()
        if name in entries and entries[name] != digest:
            report.error(f"{path}: conflicting hashes for {name}")
        entries[name] = digest
    return entries


def expected_names(version: str, scope: str) -> Dict[str, bool]:
    """Return artifact name -> required."""
    names: Dict[str, bool] = {}
    if scope in ("all", "macos"):
        names[f"MelonTools-{version}.dmg"] = True
    if scope in ("all", "windows"):
        names[f"MelonTools-{version}-setup.exe"] = True
        names[f"MelonTools-{version}-win-x64-portable.exe"] = True
        names[f"MelonTools-{version}-win-x64.exe"] = False
    return names


def artifact_hashes(
    directory: Path, names: Iterable[str], report: Report
) -> Dict[str, str]:
    hashes: Dict[str, str] = {}
    for name in names:
        path = directory / name
        if not path.is_file():
            continue
        hashes[name] = sha256_file(path)
        sibling = directory / f"{name}.sha256"
        if sibling.is_file():
            match = HEX64.search(sibling.read_text(encoding="utf-8"))
            if not match:
                report.error(f"{sibling}: no SHA-256 digest")
            elif match.group(0).lower() != hashes[name]:
                report.error(
                    f"{sibling}: digest does not match {name} "
                    f"({match.group(0).lower()} != {hashes[name]})"
                )
        else:
            report.note(f"{name}: no .sha256 sibling")
    return hashes


def compare(
    label: str,
    manifest: Optional[str],
    actual: Optional[str],
    report: Report,
    warn_only_hashes: bool = False,
) -> None:
    if not manifest:
        report.error(f"{label}: hash is missing")
        return
    if not actual:
        report.note(f"{label}: no artifact to compare (hash {manifest})")
        return
    if manifest.lower() != actual.lower():
        message = f"{label}: manifest {manifest.lower()} does not match artifact {actual.lower()}"
        if warn_only_hashes:
            report.warn(message)
        else:
            report.error(message)


def stage_release(args: argparse.Namespace, root: Path, report: Report) -> int:
    """Generate draft distribution metadata from real built artifacts.

    Nothing is written to the committed manifests: the output is a staging
    directory a release owner reviews and promotes. Missing artifacts are an
    error; this function never invents placeholder hashes.
    """
    version = args.stage
    if not SEMVER.match(version):
        report.error(
            f"--stage {version}: expected MAJOR.MINOR.PATCH "
            "or MAJOR.MINOR.PATCH-PRERELEASE"
        )
        return report.finish()
    if not args.artifacts:
        report.error("--stage requires --artifacts DIR with the built release files")
        return report.finish()
    if args.write:
        report.error("--stage and --write are mutually exclusive")
        return report.finish()

    artifacts: Path = args.artifacts.resolve()
    if not artifacts.is_dir():
        report.error(f"{artifacts}: not a directory")
        return report.finish()

    names = expected_names(version, "all")
    hashes = artifact_hashes(artifacts, names, report)
    for name, required in names.items():
        if required and name not in hashes:
            report.error(f"{artifacts}: missing required artifact {name}")
        if name in hashes and not (artifacts / f"{name}.sha256").is_file():
            report.error(f"{artifacts}: missing {name}.sha256 sibling")
    portable = f"MelonTools-{version}-win-x64-portable.exe"
    legacy = f"MelonTools-{version}-win-x64.exe"
    if legacy in hashes and portable in hashes and hashes[legacy] != hashes[portable]:
        report.error(f"{legacy} must equal {portable}; it is a legacy alias")
    if portable not in hashes or f"MelonTools-{version}-setup.exe" not in hashes:
        report.error("--stage needs both the portable exe and the NSIS setup exe")
    if f"MelonTools-{version}.dmg" not in hashes:
        report.error("--stage needs the macOS DMG")
    if report.errors:
        return report.finish()

    cask_path = root / CASK_PATH.relative_to(ROOT)
    installer_path = root / WINGET_INSTALLER.relative_to(ROOT)
    version_path = root / WINGET_VERSION.relative_to(ROOT)
    locale_path = root / WINGET_LOCALE.relative_to(ROOT)
    cask_text = read_text(cask_path, report)
    installer_text = read_text(installer_path, report)
    version_text = read_text(version_path, report)
    locale_text = read_text(locale_path, report)
    if report.errors:
        return report.finish()

    dmg = f"MelonTools-{version}.dmg"
    setup = f"MelonTools-{version}-setup.exe"

    new_cask = re.sub(
        r'(^\s*version\s+")[^"]+(")',
        lambda match: f"{match.group(1)}{version}{match.group(2)}",
        cask_text,
        count=1,
        flags=re.MULTILINE,
    )
    new_cask = re.sub(
        r'(^\s*sha256\s+")[0-9a-fA-F]{64}(")',
        lambda match: f"{match.group(1)}{hashes[dmg]}{match.group(2)}",
        new_cask,
        count=1,
        flags=re.MULTILINE,
    )

    new_version = re.sub(
        r"(?m)^PackageVersion:.*$", f"PackageVersion: {version}", version_text, count=1
    )
    new_locale = re.sub(
        r"(?m)^PackageVersion:.*$", f"PackageVersion: {version}", locale_text, count=1
    )
    new_locale = re.sub(
        r"(?m)^ReleaseNotesUrl:.*$",
        f"ReleaseNotesUrl: https://github.com/vanich-git/MelonTools/releases/tag/v{version}",
        new_locale,
        count=1,
    )
    new_installer = re.sub(
        r"(?m)^PackageVersion:.*$", f"PackageVersion: {version}", installer_text, count=1
    )
    new_installer = re.sub(
        r"(?m)^(\s*InstallerUrl:\s*).*$",
        lambda match: (
            f"{match.group(1)}https://github.com/vanich-git/MelonTools/"
            f"releases/download/v{version}/{setup}"
        ),
        new_installer,
        count=1,
    )
    new_installer = re.sub(
        r"(?m)^(\s*InstallerSha256:\s*)[0-9a-fA-F]{64}\s*$",
        lambda match: f"{match.group(1)}{hashes[setup].upper()}",
        new_installer,
        count=1,
    )

    out: Path = (args.out or root / "packaging/staging" / version).resolve()
    generated = [
        out / "homebrew",
        out / "winget",
        out / "SHA256SUMS",
    ]
    if out.exists() and any(path.exists() for path in generated):
        report.error(
            f"{out}: already contains generated metadata; remove it before regenerating"
        )
        return report.finish()

    files = {
        "homebrew/Casks/melon-tools.rb": new_cask,
        "winget/vanich-git.MelonTools.yaml": new_version,
        "winget/vanich-git.MelonTools.installer.yaml": new_installer,
        "winget/vanich-git.MelonTools.locale.en-US.yaml": new_locale,
    }
    sums = "".join(
        f"{hashes[name]}  {name}\n" for name in sorted(hashes)
    )
    packaging_section = f"""## Release artifacts for {version}

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-{version}.dmg` | `{hashes[dmg]}` |
| Windows installer | `MelonTools-{version}-setup.exe` | `{hashes[setup]}` |
| Windows portable | `MelonTools-{version}-win-x64-portable.exe` | `{hashes[portable]}` |

All files and their `.sha256` siblings are attached to the GitHub release for
tag `v{version}`.
"""
    metadata = {
        "version": version,
        "generated_by": "scripts/verify_release_checksums.py --stage",
        "artifacts": {name: hashes[name] for name in sorted(hashes)},
    }
    readme = f"""# Release metadata staging for {version}

Generated from real artifacts in `{artifacts}`. This directory is a **draft**:
the committed manifests still describe the last published release.

Do not publish or tag until a human has:

1. uploaded the matching artifacts to a **draft** GitHub release;
2. verified every hash below against the downloaded assets;
3. copied these files over the committed manifests
   (`homebrew/Casks/melon-tools.rb` and `winget/*.yaml`);
4. appended `PACKAGING_README.section.md` to `packaging/README.md` and updated
   the README "what's new" headings to {version};
5. run `python3 scripts/verify_release_checksums.py --version {version}` and
   `python3 .github/scripts/docs_lint.py --release {version}`;
6. reviewed `docs/RELEASE_ACCEPTANCE.md`.

If any artifact is rebuilt, regenerate this directory; never hand-edit a hash.

## SHA-256

```
{sums}```
"""
    (out / "homebrew/Casks").mkdir(parents=True, exist_ok=True)
    (out / "winget").mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (out / name).write_text(text, encoding="utf-8")
    (out / "SHA256SUMS").write_text(sums, encoding="utf-8")
    (out / "PACKAGING_README.section.md").write_text(
        packaging_section, encoding="utf-8"
    )
    (out / "RELEASE_METADATA.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    (out / "README.md").write_text(readme, encoding="utf-8")
    print(f"staged {version} metadata in {out}")
    print(sums, end="")
    report.note("staging output is not published; promote it only after the draft assets are verified")
    return report.finish()


def check_live_provenance(
    root: Path,
    version: str,
    cask: Dict[str, Optional[str]],
    installer: Dict[str, Optional[str]],
    report: Report,
    require: bool = False,
) -> None:
    """Guard live manifests against the generated staging provenance.

    A version that has a ``packaging/staging/<version>/`` directory must carry
    the ``RELEASE_METADATA.json``/``SHA256SUMS`` emitted by ``--stage``, and the
    live Cask/winget hashes must equal that metadata. This is what makes a
    hand-written 64-hex value fail closed even when the static version/URL
    checks would otherwise pass.
    """
    staging = root / "packaging" / "staging" / version
    metadata_path = staging / "RELEASE_METADATA.json"
    if not staging.is_dir():
        if require:
            report.error(
                f"{staging}: no generated provenance for live version {version}; "
                "run scripts/verify_release_checksums.py --stage"
            )
        return
    if not metadata_path.is_file():
        report.error(
            f"{metadata_path}: live version {version} has no generated provenance; "
            "run scripts/verify_release_checksums.py --stage"
        )
        return
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        report.error(f"{metadata_path}: invalid JSON: {exc}")
        return
    if metadata.get("version") != version:
        report.error(f"{metadata_path}: version does not match live {version}")
        return
    if "verify_release_checksums.py --stage" not in str(
        metadata.get("generated_by", "")
    ):
        report.error(f"{metadata_path}: not generated by --stage")
        return
    artifacts = metadata.get("artifacts") or {}
    dmg = f"MelonTools-{version}.dmg"
    setup = f"MelonTools-{version}-setup.exe"
    if (cask.get("sha256") or "").lower() != artifacts.get(dmg):
        report.error(
            f"Homebrew Cask: live sha256 does not match {metadata_path}"
        )
    if (installer.get("sha256") or "").lower() != artifacts.get(setup):
        report.error(
            f"winget installer: live InstallerSha256 does not match {metadata_path}"
        )
    sums_path = staging / "SHA256SUMS"
    if not sums_path.is_file():
        report.error(f"{sums_path}: generated provenance is missing")
        return
    for number, line in enumerate(sums_path.read_text(encoding="utf-8").splitlines(), 1):
        match = SUMS_LINE.match(line.strip())
        if not match:
            if line.strip():
                report.error(f"{sums_path}: line {number} is malformed")
            continue
        name = Path(match.group(2)).name
        if name in (dmg, setup) and match.group(1).lower() != artifacts.get(name):
            report.error(
                f"{sums_path}: {name} digest differs from RELEASE_METADATA.json"
            )


METADATA_ZIP = re.compile(r"^MelonTools-.*-release-metadata\.zip$")

# A stable "latest" alias must be a byte-identical copy of its versioned file.
STABLE_ALIASES = {
    "MelonTools.dmg": "MelonTools-{version}.dmg",
    "MelonTools-setup.exe": "MelonTools-{version}-setup.exe",
    "MelonTools-win-x64-portable.exe": "MelonTools-{version}-win-x64-portable.exe",
    "MelonTools-win-x64.exe": "MelonTools-{version}-win-x64.exe",
}


def verify_staged(args: "argparse.Namespace", report: "Report") -> int:
    """Verify built artifacts against the metadata emitted by ``--stage``.

    This is the build-phase gate: the bytes are signed and timestamped by the
    build, so the committed manifests cannot describe them yet. The check is
    strict: every versioned artifact must be listed with its real digest, every
    published sibling must match, and stable aliases must be exact copies. No
    placeholder or hand-edited hash survives it.
    """
    staging: Path = args.verify_staged.resolve()
    if args.stage or args.write:
        report.error("--verify-staged cannot be combined with --stage or --write")
        return report.finish()
    if args.warn_only or args.warn_on_hash_drift:
        # This is the blocking build gate; a warning-only run would let
        # unverified bytes reach a draft. Fail here, before Report could
        # downgrade the error to a warning.
        print(
            "release-checksums: FAILED\n"
            "  - --verify-staged is strict and cannot be combined with "
            "--warn-only or --warn-on-hash-drift"
        )
        return 1
    if not args.artifacts:
        report.error("--verify-staged requires --artifacts DIR")
        return report.finish()
    artifacts: Path = args.artifacts.resolve()
    if not artifacts.is_dir():
        report.error(f"{artifacts}: not a directory")
        return report.finish()

    metadata_path = staging / "RELEASE_METADATA.json"
    if not metadata_path.is_file():
        report.error(f"{metadata_path}: missing; run --stage first")
        return report.finish()
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        report.error(f"{metadata_path}: invalid JSON: {exc}")
        return report.finish()
    if not isinstance(metadata, dict):
        report.error(f"{metadata_path}: expected a JSON object")
        return report.finish()

    version = str(metadata.get("version") or "")
    if not SEMVER.match(version):
        report.error(
            f"{metadata_path}: version {version!r} is not "
            "MAJOR.MINOR.PATCH[-PRERELEASE]"
        )
        return report.finish()
    if args.version and args.version != version:
        report.error(
            f"--version {args.version} does not match staged metadata ({version})"
        )
    if "verify_release_checksums.py --stage" not in str(
        metadata.get("generated_by", "")
    ):
        report.error(f"{metadata_path}: not generated by --stage")
        return report.finish()

    hashes = metadata.get("artifacts")
    if not isinstance(hashes, dict) or not hashes:
        report.error(f"{metadata_path}: 'artifacts' must be a non-empty object")
        return report.finish()

    declared: Dict[str, str] = {}
    for name, digest in hashes.items():
        if not isinstance(name, str) or not isinstance(digest, str):
            report.error(f"{metadata_path}: malformed artifact entry {name!r}")
            continue
        # Never follow a path out of the artifacts directory.
        if Path(name).name != name or name in (".", ".."):
            report.error(f"{metadata_path}: unsafe artifact name {name!r}")
            continue
        if not re.fullmatch(r"[0-9a-f]{64}", digest.lower()):
            report.error(f"{metadata_path}: {name} has no real 64-hex digest")
            continue
        declared[name] = digest.lower()

    required = expected_names(version, "all")
    for name, is_required in required.items():
        if is_required and name not in declared:
            report.error(f"{metadata_path}: missing required artifact {name}")

    # Completeness in the other direction: every release asset the draft would
    # publish must be covered by the metadata. Matching on the bare name (not on
    # a three-part version) also catches a leftover stable file, such as
    # MelonTools-6.0.0.dmg next to MelonTools-6.0.0-rc.1.dmg.
    for path in sorted(artifacts.iterdir()):
        if not path.is_file() or path.name.endswith(".sha256"):
            continue
        if METADATA_ZIP.match(path.name):
            continue
        if (
            path.name.startswith("MelonTools-")
            and path.name not in STABLE_ALIASES
            and path.name not in declared
        ):
            report.error(
                f"{path.name}: asset is not covered by {metadata_path.name}"
            )

    for name, expected in declared.items():
        path = artifacts / name
        if not path.is_file():
            report.error(f"{artifacts}: missing artifact {name}")
            continue
        actual = sha256_file(path)
        if actual != expected:
            report.error(
                f"{name}: staged digest does not match the artifact "
                f"({expected} != {actual})"
            )
        sibling = artifacts / f"{name}.sha256"
        if not sibling.is_file():
            report.error(f"{sibling}: missing .sha256 sibling")
            continue
        match = HEX64.search(sibling.read_text(encoding="utf-8"))
        if not match:
            report.error(f"{sibling}: no SHA-256 digest")
        elif match.group(0).lower() != expected:
            report.error(f"{sibling}: digest does not match {name}")

    staged_sums = staging / "SHA256SUMS"
    if not staged_sums.is_file():
        report.error(f"{staged_sums}: missing; run --stage first")
    else:
        entries = parse_sums(staged_sums, report)
        for name, digest in declared.items():
            if entries.get(name) != digest:
                report.error(f"{staged_sums}: {name} does not match the metadata")
        for name in entries:
            if name.startswith(f"MelonTools-{version}") and name not in declared:
                report.error(f"{staged_sums}: unexpected versioned asset {name}")

    for path in args.sha256sums:
        if not path.is_file():
            report.error(f"{path}: SHA256SUMS file is missing")
            continue
        for name, digest in parse_sums(path, report).items():
            if name in declared and declared[name] != digest:
                report.error(f"{path}: {name} digest differs from the metadata")
            if name.startswith(f"MelonTools-{version}") and name not in declared:
                report.error(f"{path}: unexpected versioned asset {name}")
            alias = STABLE_ALIASES.get(name)
            if alias:
                versioned = alias.format(version=version)
                if declared.get(versioned) != digest:
                    report.error(
                        f"{path}: {name} is not a copy of {versioned}"
                    )

    return report.finish()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    parser.add_argument("--version", help="expected release version (for example 2.4.0)")
    parser.add_argument(
        "--artifacts", type=Path, help="directory containing the built release artifacts"
    )
    parser.add_argument(
        "--sha256sums",
        type=Path,
        action="append",
        default=[],
        help="SHA256SUMS file to read (may be passed more than once)",
    )
    parser.add_argument(
        "--only",
        choices=["all", "macos", "windows"],
        default="all",
        help="platform to verify when --artifacts is used",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="write the hashes from --artifacts/--sha256sums into the manifests",
    )
    parser.add_argument(
        "--stage",
        metavar="VERSION",
        help=(
            "generate draft Homebrew/winget metadata for VERSION from "
            "--artifacts into --out; never edits the committed manifests"
        ),
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="staging output directory (default packaging/staging/<version>)",
    )
    parser.add_argument(
        "--verify-staged",
        type=Path,
        metavar="DIR",
        help=(
            "strictly verify --artifacts (and any --sha256sums files) against "
            "the RELEASE_METADATA.json/SHA256SUMS emitted by --stage; used by "
            "the build/draft phase before the manifests are promoted"
        ),
    )
    parser.add_argument(
        "--require-provenance",
        action="store_true",
        help=(
            "fail when the live version has no packaging/staging/<version>/ "
            "RELEASE_METADATA.json generated by --stage"
        ),
    )
    parser.add_argument(
        "--warn-only",
        action="store_true",
        help="report mismatches without failing (for rebuild jobs)",
    )
    parser.add_argument(
        "--warn-on-hash-drift",
        action="store_true",
        help="fail on version/URL problems but only warn when a built artifact differs",
    )
    args = parser.parse_args(argv)

    report = Report(warn_only=args.warn_only)
    root: Path = args.root.resolve()

    if args.stage:
        return stage_release(args, root, report)
    if args.verify_staged:
        return verify_staged(args, report)

    cask_path = root / CASK_PATH.relative_to(ROOT)
    installer_path = root / WINGET_INSTALLER.relative_to(ROOT)
    version_path = root / WINGET_VERSION.relative_to(ROOT)
    locale_path = root / WINGET_LOCALE.relative_to(ROOT)

    cask_text = read_text(cask_path, report)
    installer_text = read_text(installer_path, report)
    version_text = read_text(version_path, report)
    locale_text = read_text(locale_path, report)

    cask = parse_cask(cask_text)
    installer = parse_winget_installer(installer_text)
    winget_versions = {
        f"winget {p.name}": parse_winget_version(text)
        for p, text in (
            (installer_path, installer_text),
            (version_path, version_text),
            (locale_path, locale_text),
        )
        if text
    }

    versions = {
        "Homebrew Cask": cask.get("version"),
        **winget_versions,
    }
    if args.version:
        versions["--version"] = args.version
        if not SEMVER.match(args.version):
            report.error(
                f"--version {args.version}: expected MAJOR.MINOR.PATCH "
                "or MAJOR.MINOR.PATCH-PRERELEASE"
            )

    non_empty = {name: value for name, value in versions.items() if value}
    distinct = sorted(set(non_empty.values()))
    if len(distinct) > 1:
        report.error(f"version mismatch across release files: {versions}")
    version = distinct[0] if distinct else None

    if args.version and version and args.version != version:
        report.error(f"--version {args.version} does not match manifests ({version})")

    if not version:
        report.error("could not determine the release version")
        return report.finish()

    if not (cask.get("sha256") or "").strip():
        report.error("Homebrew Cask: sha256 is missing")
    if not (installer.get("sha256") or "").strip():
        report.error("winget installer manifest: InstallerSha256 is missing")

    # Versioned URLs must point at the same version as the package metadata.
    cask_url = cask.get("url") or ""
    if cask_url:
        if "releases/download/v#{version}/" not in cask_url:
            report.error("Homebrew Cask: URL does not use the cask version")
        if "MelonTools-#{version}.dmg" not in cask_url:
            report.error("Homebrew Cask: URL does not point at the versioned DMG")

    installer_url = installer.get("url") or ""
    if installer_url:
        url_version = search(r"/releases/download/v([^/]+)/", installer_url)
        # Strip the known artifact suffix instead of matching a catch-all
        # version pattern: "5.5.8-setup.exe" must parse as 5.5.8, not as the
        # prerelease "5.5.8-setup.exe".
        file_name = installer_url.rsplit("/", 1)[-1]
        file_version = None
        for suffix in ("-setup.exe", "-win-x64-portable.exe", "-win-x64.exe"):
            if file_name.startswith("MelonTools-") and file_name.endswith(suffix):
                file_version = file_name[len("MelonTools-"):-len(suffix)]
                break
        if url_version != version:
            report.error(
                f"winget installer: URL version {url_version!r} does not match {version}"
            )
        if file_version != version:
            report.error(
                f"winget installer: file name version {file_version!r} "
                f"does not match {version}"
            )
        if not installer_url.startswith(
            "https://github.com/vanich-git/MelonTools/releases/download/"
        ):
            report.error("winget installer: URL is not a GitHub release URL")

    check_live_provenance(
        root,
        version,
        cask,
        installer,
        report,
        require=args.require_provenance,
    )

    names = expected_names(version, args.only)

    # --- Collect truth from built artifacts and/or SHA256SUMS -----------------
    sums: Dict[str, str] = {}
    if args.artifacts:
        if not args.artifacts.is_dir():
            report.error(f"{args.artifacts}: not a directory")
        else:
            hashes = artifact_hashes(args.artifacts, names, report)
            sums.update(hashes)
            for name, required in names.items():
                if name not in hashes and required:
                    report.error(f"{args.artifacts}: missing required artifact {name}")

    sums_files = list(args.sha256sums)
    if not sums_files:
        for candidate in (
            root / "SHA256SUMS",
            root / "packaging/SHA256SUMS",
            (args.artifacts / "SHA256SUMS") if args.artifacts else None,
        ):
            if candidate and candidate.is_file():
                sums_files.append(candidate)
    for path in sums_files:
        if not path.is_file():
            report.error(f"{path}: SHA256SUMS file is missing")
            continue
        for name, digest in parse_sums(path, report).items():
            if name in sums and sums[name] != digest:
                report.error(
                    f"{path}: {name} hash differs from the artifact ({digest} != {sums[name]})"
                )
            sums.setdefault(name, digest)

    # --- Compare the manifests with the truth --------------------------------
    dmg = f"MelonTools-{version}.dmg"
    setup = f"MelonTools-{version}-setup.exe"
    portable = f"MelonTools-{version}-win-x64-portable.exe"
    legacy = f"MelonTools-{version}-win-x64.exe"

    # Version, URL and structural problems must be fixed by hand; a hash from
    # a fresh build is exactly what --write is meant to record.
    static_errors = len(report.errors)
    compare(
        f"Homebrew Cask ({dmg})",
        cask.get("sha256"),
        sums.get(dmg),
        report,
        warn_only_hashes=args.warn_on_hash_drift or args.write,
    )
    compare(
        f"winget installer ({setup})",
        installer.get("sha256"),
        sums.get(setup),
        report,
        warn_only_hashes=args.warn_on_hash_drift or args.write,
    )
    if portable in sums and legacy in sums and sums[portable] != sums[legacy]:
        report.error(
            f"{legacy} is a legacy alias and must equal {portable} "
            f"({sums[legacy]} != {sums[portable]})"
        )

    # A manifest hash that appears in neither an artifact nor SHA256SUMS cannot
    # be verified; that is expected in a plain checkout, but worth a note.
    if not sums:
        report.note(
            "no artifacts or SHA256SUMS were supplied; only static manifest checks ran"
        )

    if args.write:
        if not sums.get(dmg) or not sums.get(setup):
            report.error(
                "--write requires both the DMG and the setup executable in "
                "--artifacts or --sha256sums"
            )
        elif static_errors or report.errors:
            report.error("refusing to write manifests while version or URL checks fail")
        else:
            new_cask = re.sub(
                r'(^\s*sha256\s+")[0-9a-fA-F]{64}(")',
                lambda match: f"{match.group(1)}{sums[dmg]}{match.group(2)}",
                cask_text,
                count=1,
                flags=re.MULTILINE,
            )
            new_installer = re.sub(
                r"(^\s*InstallerSha256:\s*)[0-9a-fA-F]{64}\s*$",
                lambda match: f"{match.group(1)}{sums[setup].upper()}",
                installer_text,
                count=1,
                flags=re.MULTILINE,
            )
            changed = False
            if new_cask != cask_text:
                cask_path.write_text(new_cask, encoding="utf-8")
                print(f"updated {cask_path}")
                changed = True
            if new_installer != installer_text:
                installer_path.write_text(new_installer, encoding="utf-8")
                print(f"updated {installer_path}")
                changed = True
            if not changed:
                print("manifests already match the artifacts")

    return report.finish()


if __name__ == "__main__":
    sys.exit(main())
