#!/usr/bin/env python3
"""Basic repository lint for docs and distribution manifests.

Checks run in CI (`.github/workflows/ci.yml`) and can be run locally:

    python3 .github/scripts/docs_lint.py

A release has two gates because signing timestamps change the artifacts:

    python3 .github/scripts/docs_lint.py --release 6.0.0 --preflight  # before tagging
    python3 .github/scripts/docs_lint.py --release 6.0.0              # before publishing

The lint intentionally avoids third-party tooling beyond PyYAML. It verifies
that workflow/manifest YAML and JSON parse, that release versions agree across
the macOS project, the Windows crate and the distribution manifests, and that
the documented files exist and are linked from the root README.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
ERRORS: list[str] = []
NOTES: list[str] = []

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--release",
    metavar="VERSION",
    help=(
        "promotion gate: the application and release notes must describe "
        "VERSION; unless --preflight is given, the published distribution "
        "manifests must also carry VERSION's generated staged hashes"
    ),
)
parser.add_argument(
    "--preflight",
    action="store_true",
    help=(
        "with --release: build-phase check only. Requires the sources and "
        "release notes to describe VERSION, but does not require Homebrew/"
        "winget to be promoted yet. Use before the build, because code-signing "
        "timestamps produce the real hashes only during the build; the strict "
        "promotion gate runs after the draft exists"
    ),
)
ARGS = parser.parse_args()
RELEASE_VERSION = ARGS.release
PREFLIGHT = ARGS.preflight
if PREFLIGHT and not RELEASE_VERSION:
    parser.error("--preflight requires --release VERSION")


def semver(value: str | None) -> tuple[int, int, int, int, str] | None:
    """Parse ``MAJOR.MINOR.PATCH[-PRERELEASE]`` into a sortable tuple.

    The fourth element ranks a final release above any of its prereleases
    (``6.0.0`` > ``6.0.0-rc.1``), so a prerelease never looks newer than the
    stable release it leads to. The fifth element orders prerelease strings
    lexically, which is enough for the comparisons this lint performs.
    """
    match = re.fullmatch(
        r"(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?", value or ""
    )
    if not match:
        return None
    major, minor, patch, prerelease = match.groups()
    return (
        int(major),
        int(minor),
        int(patch),
        0 if prerelease else 1,
        prerelease or "",
    )


def winget_installer_sha(document: object) -> str:
    if not isinstance(document, dict):
        return ""
    installers = document.get("Installers")
    if isinstance(installers, list):
        for entry in installers:
            if isinstance(entry, dict) and entry.get("InstallerSha256"):
                return str(entry["InstallerSha256"]).lower()
    value = document.get("InstallerSha256", "")
    return str(value).lower()



def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def check_yaml(path: Path) -> object | None:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return yaml.safe_load(handle)
    except Exception as exc:  # noqa: BLE001 - report every parse failure
        ERRORS.append(f"{rel(path)}: invalid YAML: {exc}")
        return None


def check_json(path: Path) -> None:
    try:
        with path.open("r", encoding="utf-8") as handle:
            json.load(handle)
    except Exception as exc:  # noqa: BLE001
        ERRORS.append(f"{rel(path)}: invalid JSON: {exc}")


def find_files(pattern: str) -> list[Path]:
    return sorted(
        path
        for path in ROOT.glob(pattern)
        if path.is_file() and not path.name.startswith("._")
    )


# --- YAML and JSON syntax -------------------------------------------------

workflow_files = find_files(".github/workflows/*.yml")
if not workflow_files:
    ERRORS.append(".github/workflows: no workflow files found")

for path in workflow_files:
    document = check_yaml(path)
    if isinstance(document, dict) and "jobs" not in document:
        ERRORS.append(f"{rel(path)}: workflow has no jobs section")

for path in find_files(".github/ISSUE_TEMPLATE/*.yml"):
    check_yaml(path)

dependabot = ROOT / ".github/dependabot.yml"
if dependabot.is_file():
    document = check_yaml(dependabot)
    if isinstance(document, dict) and "updates" not in document:
        ERRORS.append(f"{rel(dependabot)}: no updates entries")
else:
    ERRORS.append(".github/dependabot.yml: missing")

winget_files = find_files("packaging/winget/*.yaml")
if len(winget_files) != 3:
    ERRORS.append(
        "packaging/winget: expected version, installer, and locale manifests; "
        f"found {len(winget_files)}"
    )
for path in winget_files:
    check_yaml(path)

for path in [
    ROOT / "Windows/app/src-tauri/tauri.conf.json",
    *find_files("Windows/app/src-tauri/capabilities/*.json"),
]:
    if path.is_file():
        check_json(path)

# --- Version consistency --------------------------------------------------

project_yaml = ROOT / "MacOS/app/project.yml"
project_version = None
if project_yaml.is_file():
    project = check_yaml(project_yaml)
    try:
        project_version = project["targets"]["MelonTools"]["info"]["properties"][
            "CFBundleShortVersionString"
        ]
    except (KeyError, TypeError):
        ERRORS.append("MacOS/app/project.yml: could not read the bundle version")
else:
    ERRORS.append("MacOS/app/project.yml: missing")

cargo_version = None
cargo_toml = ROOT / "Windows/app/src-tauri/Cargo.toml"
if cargo_toml.is_file():
    match = re.search(
        r'^version\s*=\s*"([^"]+)"', cargo_toml.read_text(encoding="utf-8"), re.MULTILINE
    )
    cargo_version = match.group(1) if match else None
else:
    ERRORS.append("Windows/app/src-tauri/Cargo.toml: missing")

lock_version = None
cargo_lock = ROOT / "Windows/app/src-tauri/Cargo.lock"
if cargo_lock.is_file():
    match = re.search(
        r'\[\[package\]\]\s*\nname = "melontools"\s*\nversion = "([^"]+)"',
        cargo_lock.read_text(encoding="utf-8"),
    )
    lock_version = match.group(1) if match else None
    if not lock_version:
        ERRORS.append("Cargo.lock: melontools package version not found")
else:
    ERRORS.append("Windows/app/src-tauri/Cargo.lock: missing")

tauri_version = None
tauri_conf = ROOT / "Windows/app/src-tauri/tauri.conf.json"
if tauri_conf.is_file():
    tauri_version = (json.loads(tauri_conf.read_text(encoding="utf-8")) or {}).get("version")
    if not tauri_version:
        ERRORS.append("tauri.conf.json: version is missing")

plist_version = None
info_plist = ROOT / "MacOS/app/MelonTools/Info.plist"
if info_plist.is_file():
    match = re.search(
        r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>",
        info_plist.read_text(encoding="utf-8"),
    )
    plist_version = match.group(1) if match else None
    if not plist_version:
        ERRORS.append("Info.plist: CFBundleShortVersionString is missing")

release_notes = ROOT / "MacOS/RELEASE_NOTES.md"
release_notes_version = None
if release_notes.is_file():
    match = re.search(
        r"^# Melon Tools ([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?)$",
        release_notes.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    release_notes_version = match.group(1) if match else None
    if not release_notes_version:
        ERRORS.append("MacOS/RELEASE_NOTES.md: first heading has no version")
else:
    ERRORS.append("MacOS/RELEASE_NOTES.md: missing")

cask_path = ROOT / "packaging/homebrew/Casks/melon-tools.rb"
cask_text = cask_path.read_text(encoding="utf-8") if cask_path.is_file() else ""
cask_version_match = re.search(r'^\s*version\s+"([^"]+)"', cask_text, re.MULTILINE)
cask_sha_match = re.search(r'^\s*sha256\s+"([0-9a-fA-F]{64})"', cask_text, re.MULTILINE)
if not cask_path.is_file():
    ERRORS.append("packaging/homebrew/Casks/melon-tools.rb: missing")
if not cask_version_match:
    ERRORS.append("Homebrew Cask: version is missing")
if not cask_sha_match:
    ERRORS.append("Homebrew Cask: sha256 is missing or not 64 hex characters")

winget_versions: dict[str, object] = {}
winget_sha = None
for path in winget_files:
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    winget_versions[path.name] = document.get("PackageVersion")
    if "InstallerSha256" in document:
        winget_sha = str(document["InstallerSha256"]).lower()
        if not re.fullmatch(r"[0-9a-f]{64}", winget_sha):
            ERRORS.append(f"{rel(path)}: InstallerSha256 is not 64 hex characters")

# Application sources describe what this checkout builds. They must always
# agree with each other.
app_versions = {
    "MacOS/app/project.yml": project_version,
    "Windows/app/src-tauri/Cargo.toml": cargo_version,
    "Windows/app/src-tauri/Cargo.lock": lock_version,
    "Windows/app/src-tauri/tauri.conf.json": tauri_version,
    "MacOS/app/MelonTools/Info.plist": plist_version,
    "MacOS/RELEASE_NOTES.md": release_notes_version,
}
app_known = {version for version in app_versions.values() if version}
if len(app_known) != 1:
    ERRORS.append(f"application version mismatch across sources: {app_versions}")
app_version = next(iter(app_known), None)
if app_version and not semver(app_version):
    ERRORS.append(f"application version is not MAJOR.MINOR.PATCH: {app_version}")

# Distribution manifests describe the last *published* artifacts. They are
# a separate version stream: an unreleased application version must not be
# written into Homebrew/winget before real artifacts exist. Both streams must
# be internally consistent, and distribution may never run ahead of the app.
distribution_versions = {
    "Homebrew Cask": cask_version_match.group(1) if cask_version_match else None,
    **{f"winget {name}": version for name, version in winget_versions.items()},
}
distribution_known = {
    version for version in distribution_versions.values() if version
}
if len(distribution_known) != 1:
    ERRORS.append(
        "published distribution version mismatch across manifests: "
        f"{distribution_versions}"
    )
distribution_version = next(iter(distribution_known), None)
if distribution_version and not semver(distribution_version):
    ERRORS.append(
        f"distribution version is not MAJOR.MINOR.PATCH: {distribution_version}"
    )

for name, version in {**app_versions, **distribution_versions}.items():
    if not version:
        ERRORS.append(f"{name}: version is missing")

if app_version and distribution_version:
    app_parts = semver(app_version)
    distribution_parts = semver(distribution_version)
    if app_parts and distribution_parts:
        if distribution_parts > app_parts:
            ERRORS.append(
                "distribution manifests are newer than the application: "
                f"{distribution_version} > {app_version}"
            )
        elif distribution_parts < app_parts:
            NOTES.append(
                f"application {app_version} is unreleased; Homebrew/winget still "
                f"describe the published {distribution_version}. Run "
                "scripts/verify_release_checksums.py --stage before tagging."
            )

if RELEASE_VERSION:
    release_parts = semver(RELEASE_VERSION)
    if not release_parts:
        ERRORS.append(
            f"--release {RELEASE_VERSION}: expected MAJOR.MINOR.PATCH "
            "or MAJOR.MINOR.PATCH-PRERELEASE"
        )
    if app_version != RELEASE_VERSION:
        ERRORS.append(
            f"--release {RELEASE_VERSION}: application sources are {app_version}"
        )
    if release_notes_version != RELEASE_VERSION:
        ERRORS.append(
            f"--release {RELEASE_VERSION}: release notes are {release_notes_version}"
        )
    if release_notes.is_file():
        head = "\n".join(
            release_notes.read_text(encoding="utf-8").splitlines()[:6]
        ).lower()
        if "draft release notes" in head and not PREFLIGHT:
            ERRORS.append(
                f"--release {RELEASE_VERSION}: RELEASE_NOTES.md still says "
                "'draft release notes'"
            )

    if PREFLIGHT:
        # Build phase. Distribution manifests intentionally still describe the
        # last published release; the real hashes do not exist until after
        # code signing, so promotion is verified by the promote workflow.
        NOTES.append(
            f"--release {RELEASE_VERSION}: preflight accepted; Homebrew/winget "
            "promotion and staged metadata are verified before publishing"
        )
    elif "-" in RELEASE_VERSION:
        # A prerelease ships through the draft → GitHub prerelease path only.
        # Homebrew/winget describe stable artifacts, so promoting an RC there
        # would offer a test build to every `brew upgrade` and `winget upgrade`.
        ERRORS.append(
            f"--release {RELEASE_VERSION}: prereleases are not promoted into "
            "Homebrew/winget; publish the draft as a GitHub prerelease instead"
        )
    else:
        if distribution_version != RELEASE_VERSION:
            ERRORS.append(
                f"--release {RELEASE_VERSION}: Homebrew/winget still describe "
                f"{distribution_version}; promote the staged metadata before tagging"
            )
        # Fail closed without machine-generated provenance. A hand-written 64-hex
        # value is indistinguishable from a real digest at lint time, so --release
        # requires the staging directory produced by
        # `verify_release_checksums.py --stage` and matches every live hash to it.
        staging_dir = ROOT / "packaging/staging" / RELEASE_VERSION
        metadata_path = staging_dir / "RELEASE_METADATA.json"
        sums_path = staging_dir / "SHA256SUMS"
        staged_cask_path = staging_dir / "homebrew/Casks/melon-tools.rb"
        staged_installer_path = (
            staging_dir / "winget/vanich-git.MelonTools.installer.yaml"
        )
        required_staging = [
            metadata_path,
            sums_path,
            staged_cask_path,
            staged_installer_path,
        ]
        missing_staging = [rel(path) for path in required_staging if not path.is_file()]
        if missing_staging:
            ERRORS.append(
                f"--release {RELEASE_VERSION}: missing generated staging metadata "
                f"({', '.join(missing_staging)}); run "
                "scripts/verify_release_checksums.py --stage with the real artifacts"
            )
        else:
            try:
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                metadata = {}
                ERRORS.append(f"{rel(metadata_path)}: invalid JSON: {exc}")
            artifacts = metadata.get("artifacts") or {}
            if metadata.get("version") != RELEASE_VERSION:
                ERRORS.append(
                    f"{rel(metadata_path)}: version is {metadata.get('version')!r}, "
                    f"expected {RELEASE_VERSION}"
                )
            if "verify_release_checksums.py --stage" not in str(
                metadata.get("generated_by", "")
            ):
                ERRORS.append(
                    f"{rel(metadata_path)}: not generated by "
                    "'verify_release_checksums.py --stage'"
                )

            dmg = f"MelonTools-{RELEASE_VERSION}.dmg"
            setup = f"MelonTools-{RELEASE_VERSION}-setup.exe"
            portable = f"MelonTools-{RELEASE_VERSION}-win-x64-portable.exe"
            legacy = f"MelonTools-{RELEASE_VERSION}-win-x64.exe"
            for name in [dmg, setup, portable]:
                digest = str(artifacts.get(name, "")).lower()
                if not re.fullmatch(r"[0-9a-f]{64}", digest):
                    ERRORS.append(
                        f"{rel(metadata_path)}: {name} has no real 64-hex digest"
                    )
            if legacy in artifacts and artifacts[legacy] != artifacts.get(portable):
                ERRORS.append(
                    f"{rel(metadata_path)}: {legacy} is not the portable alias"
                )

            staged_cask_text = staged_cask_path.read_text(encoding="utf-8")
            staged_cask_version = re.search(
                r'^\s*version\s+"([^"]+)"', staged_cask_text, re.MULTILINE
            )
            staged_cask_sha = re.search(
                r'^\s*sha256\s+"([0-9a-fA-F]{64})"', staged_cask_text, re.MULTILINE
            )
            if not staged_cask_version or staged_cask_version.group(1) != RELEASE_VERSION:
                ERRORS.append(f"{rel(staged_cask_path)}: version mismatch")
            if (
                not staged_cask_sha
                or staged_cask_sha.group(1).lower() != artifacts.get(dmg)
            ):
                ERRORS.append(
                    f"{rel(staged_cask_path)}: sha256 does not match RELEASE_METADATA.json"
                )
            if (
                not cask_sha_match
                or cask_sha_match.group(1).lower() != artifacts.get(dmg)
            ):
                ERRORS.append(
                    "Homebrew Cask: live sha256 does not match the generated staging metadata"
                )

            staged_installer = (
                yaml.safe_load(staged_installer_path.read_text(encoding="utf-8")) or {}
            )
            if staged_installer.get("PackageVersion") != RELEASE_VERSION:
                ERRORS.append(f"{rel(staged_installer_path)}: version mismatch")
            if (
                winget_installer_sha(staged_installer) != artifacts.get(setup)
            ):
                ERRORS.append(
                    f"{rel(staged_installer_path)}: InstallerSha256 does not match "
                    "RELEASE_METADATA.json"
                )
            live_installer_path = (
                ROOT / "packaging/winget/vanich-git.MelonTools.installer.yaml"
            )
            live_installer = (
                yaml.safe_load(live_installer_path.read_text(encoding="utf-8"))
                if live_installer_path.is_file()
                else {}
            ) or {}
            if winget_installer_sha(live_installer) != artifacts.get(setup):
                ERRORS.append(
                    "winget installer: live InstallerSha256 does not match the "
                    "generated staging metadata"
                )

            sums: dict[str, str] = {}
            for number, line in enumerate(
                sums_path.read_text(encoding="utf-8").splitlines(), 1
            ):
                match = re.match(r"^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$", line)
                if not match:
                    if line.strip():
                        ERRORS.append(f"{rel(sums_path)}: line {number} is malformed")
                    continue
                sums[Path(match.group(2)).name] = match.group(1).lower()
            for name in [dmg, setup, portable]:
                if sums.get(name) != artifacts.get(name):
                    ERRORS.append(
                        f"{rel(sums_path)}: {name} does not match the staged metadata"
                    )

            packaging_readme = ROOT / "packaging/README.md"
            packaging_text = (
                packaging_readme.read_text(encoding="utf-8")
                if packaging_readme.is_file()
                else ""
            )
            if artifacts.get(dmg) and artifacts[dmg] not in packaging_text:
                ERRORS.append(
                    "packaging/README.md: release section does not contain the "
                    "generated DMG digest"
                )

# --- Distribution URLs ----------------------------------------------------

version = distribution_version
if version:
    cask_url_ok = (
        f"releases/download/v#{{version}}/MelonTools-#{{version}}.dmg" in cask_text
    )
    if not cask_url_ok:
        ERRORS.append("Homebrew Cask: DMG URL does not use the cask version")

    installer_path = ROOT / "packaging/winget/vanich-git.MelonTools.installer.yaml"
    installer_text = installer_path.read_text(encoding="utf-8") if installer_path.is_file() else ""
    if not installer_text:
        ERRORS.append("winget installer manifest: missing")
    else:
        if (f"MelonTools-{version}-win-x64.exe" not in installer_text and f"MelonTools-{version}-setup.exe" not in installer_text):
            ERRORS.append("winget installer manifest: exe URL does not use the package version")
        if "https://github.com/vanich-git/MelonTools/releases/download/" not in installer_text:
            ERRORS.append("winget installer manifest: InstallerUrl is not a GitHub release URL")

    packaging_readme = ROOT / "packaging/README.md"
    packaging_text = (
        packaging_readme.read_text(encoding="utf-8")
        if packaging_readme.is_file()
        else ""
    )
    if f"## Release artifacts for {version}" not in packaging_text:
        ERRORS.append(
            f"packaging/README.md: no '## Release artifacts for {version}' section"
        )
    if (
        app_version
        and app_version != version
        and f"## Release artifacts for {app_version}" in packaging_text
    ):
        ERRORS.append(
            f"packaging/README.md: claims release artifacts for unreleased "
            f"{app_version}; use a staging section without hashes"
        )

    # Staged metadata is optional locally but must never carry a fake digest.
    for staged_version in {version, app_version}:
        staging = ROOT / "packaging/staging" / str(staged_version)
        if not staging.is_dir():
            continue
        staged_cask = staging / "homebrew/Casks/melon-tools.rb"
        if staged_cask.is_file():
            staged_text = staged_cask.read_text(encoding="utf-8")
            match = re.search(r'^\s*sha256\s+"([^"]+)"', staged_text, re.MULTILINE)
            if not match or not re.fullmatch(r"[0-9a-fA-F]{64}", match.group(1)):
                ERRORS.append(
                    f"{rel(staged_cask)}: staged sha256 is not a real 64-hex digest"
                )
        for path in sorted((staging / "winget").glob("*.yaml")):
            document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            if document.get("PackageVersion") != staged_version:
                ERRORS.append(
                    f"{rel(path)}: staged PackageVersion does not match {staged_version}"
                )
            if "InstallerSha256" in document:
                digest = str(document["InstallerSha256"]).lower()
                if not re.fullmatch(r"[0-9a-f]{64}", digest):
                    ERRORS.append(
                        f"{rel(path)}: staged InstallerSha256 is not a real 64-hex digest"
                    )

# --- Documentation --------------------------------------------------------

required_docs = {
    "docs/FAQ.md": 1500,
    "docs/SECURITY-MODEL.md": 1500,
    "packaging/README.md": 800,
}
for name, minimum in required_docs.items():
    path = ROOT / name
    if not path.is_file():
        ERRORS.append(f"{name}: missing")
    elif len(path.read_text(encoding="utf-8")) < minimum:
        ERRORS.append(f"{name}: shorter than {minimum} characters")

# The README "what's new" heading must describe the last published release,
# never the unreleased application version.
if distribution_version:
    whats_new = {
        "README.md": r"^## What's new in ([0-9]+\.[0-9]+\.[0-9]+)",
        "README.ru.md": r"^## Что нового в ([0-9]+\.[0-9]+\.[0-9]+)",
        "MacOS/README.md": r"^## What's new in ([0-9]+\.[0-9]+\.[0-9]+)",
    }
    for name, pattern in whats_new.items():
        path = ROOT / name
        if not path.is_file():
            continue
        match = re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE)
        if not match:
            ERRORS.append(f"{name}: no 'what's new in X.Y.Z' heading")
        elif match.group(1) != distribution_version:
            ERRORS.append(
                f"{name}: latest-published heading is {match.group(1)}, "
                f"but the distribution manifests describe {distribution_version}"
            )

readme = ROOT / "README.md"
if readme.is_file():
    readme_text = readme.read_text(encoding="utf-8")
    for link in ["docs/FAQ.md", "docs/SECURITY-MODEL.md"]:
        if link not in readme_text:
            ERRORS.append(f"README.md: missing documentation link to {link}")
    if re.search(r"releases/latest/download/MelonTools-[0-9]", readme_text):
        ERRORS.append("README.md: versioned filename under releases/latest/download is unstable; use a stable alias")
else:
    ERRORS.append("README.md: missing")

if release_notes.is_file():
    notes_text = release_notes.read_text(encoding="utf-8")
    if "releases/latest/download/" in notes_text:
        ERRORS.append("MacOS/RELEASE_NOTES.md: use releases/download/v<version>/ links for past releases")

# --- Distribution checksum truth -----------------------------------------

import subprocess

checksum_script = ROOT / "scripts/verify_release_checksums.py"
if checksum_script.is_file():
    result = subprocess.run(
        [sys.executable, str(checksum_script)], cwd=ROOT, text=True, capture_output=True
    )
    if result.returncode != 0:
        ERRORS.append(
            "packaging manifests disagree with checksums:\n"
            + (result.stderr or result.stdout).strip()
        )
else:
    ERRORS.append("scripts/verify_release_checksums.py: missing")

# --- Result ---------------------------------------------------------------

if ERRORS:
    print("docs-lint: FAILED")
    for error in ERRORS:
        print(f"  - {error}")
    for note in NOTES:
        print(f"  note: {note}")
    sys.exit(1)

print("docs-lint: OK")
print(f"  workflows: {len(workflow_files)}")
print(f"  winget manifests: {len(winget_files)}")
print(f"  application version: {app_version}")
print(f"  published distribution version: {distribution_version}")
for note in NOTES:
    print(f"  note: {note}")
