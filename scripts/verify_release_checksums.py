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
"""

from __future__ import annotations

import argparse
import hashlib
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
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


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
            report.error(f"--version {args.version}: expected MAJOR.MINOR.PATCH")

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
        url_name = re.search(r"/MelonTools-([0-9]+\.[0-9]+\.[0-9]+)", installer_url)
        if url_version != version:
            report.error(
                f"winget installer: URL version {url_version!r} does not match {version}"
            )
        if url_name and url_name.group(1) != version:
            report.error(
                f"winget installer: file name version {url_name.group(1)} "
                f"does not match {version}"
            )
        if not installer_url.startswith(
            "https://github.com/vanich-git/MelonTools/releases/download/"
        ):
            report.error("winget installer: URL is not a GitHub release URL")

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
