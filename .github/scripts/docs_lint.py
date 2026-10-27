#!/usr/bin/env python3
"""Basic repository lint for docs and distribution manifests.

Checks run in CI (`.github/workflows/ci.yml`) and can be run locally:

    python3 .github/scripts/docs_lint.py

The lint intentionally avoids third-party tooling beyond PyYAML. It verifies
that workflow/manifest YAML and JSON parse, that release versions agree across
the macOS project, the Windows crate and the distribution manifests, and that
the documented files exist and are linked from the root README.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
ERRORS: list[str] = []


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
    match = re.search(r"^# Melon Tools ([0-9][0-9.]*)$", release_notes.read_text(encoding="utf-8"), re.MULTILINE)
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

versions = {
    "MacOS/app/project.yml": project_version,
    "Windows/app/src-tauri/Cargo.toml": cargo_version,
    "Windows/app/src-tauri/Cargo.lock": lock_version,
    "Windows/app/src-tauri/tauri.conf.json": tauri_version,
    "MacOS/app/MelonTools/Info.plist": plist_version,
    "MacOS/RELEASE_NOTES.md": release_notes_version,
    "Homebrew Cask": cask_version_match.group(1) if cask_version_match else None,
}
for name, version in winget_versions.items():
    versions[f"winget {name}"] = version

known = {version for version in versions.values() if version}
if len(known) != 1:
    ERRORS.append(f"version mismatch across release files: {versions}")

for name, version in versions.items():
    if not version:
        ERRORS.append(f"{name}: version is missing")

# --- Distribution URLs ----------------------------------------------------

version = next(iter(known), None)
if version:
    cask_url_ok = (
        f"releases/download/v#{{version}}/MelonTools-#{{version}}.dmg" in cask_text
    )
    if not cask_url_ok:
        ERRORS.append("Homebrew Cask: DMG URL does not use the cask version")

    installer_path = ROOT / "packaging/winget/ivankuprin.MelonTools.installer.yaml"
    installer_text = installer_path.read_text(encoding="utf-8") if installer_path.is_file() else ""
    if not installer_text:
        ERRORS.append("winget installer manifest: missing")
    else:
        if (f"MelonTools-{version}-win-x64.exe" not in installer_text and f"MelonTools-{version}-setup.exe" not in installer_text):
            ERRORS.append("winget installer manifest: exe URL does not use the package version")
        if "https://github.com/ivankuprin/MelonTools/releases/download/" not in installer_text:
            ERRORS.append("winget installer manifest: InstallerUrl is not a GitHub release URL")

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
    sys.exit(1)

print("docs-lint: OK")
print(f"  workflows: {len(workflow_files)}")
print(f"  winget manifests: {len(winget_files)}")
print(f"  version: {version}")
