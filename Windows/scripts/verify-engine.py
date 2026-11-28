#!/usr/bin/env python3
"""Verify the embedded Windows gateway engine against its provenance file.

The Windows build embeds a prebuilt, compressed CLIProxyAPI binary. This
script makes the blob auditable without rebuilding it:

    python3 Windows/scripts/verify-engine.py
    python3 Windows/scripts/verify-engine.py --require-current-patches

It checks the compressed bytes, the zlib payload, and the commit prefix that
engine.rs reports. A legacy provenance file can still prove blob integrity,
but is reported as unverified: its wildcard sourceState and per-patch hashes
cannot prove which patch set produced the binary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "Windows/app/resources"
PROVENANCE = RESOURCES / "engine-provenance.json"
ENGINE_RS = ROOT / "Windows/app/src-tauri/src/engine.rs"
ERRORS: list[str] = []
WARNINGS: list[str] = []


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        ERRORS.append(f"{label}: got {actual!r}, expected {expected!r}")


def patch_files(root: Path = ROOT) -> dict[str, bytes]:
    return {
        path.name: path.read_bytes()
        for path in sorted((root / "MacOS/patches").glob("[0-9]*.patch"))
    }


def check_current_patches(provenance: dict, patches: dict[str, bytes]) -> tuple[list[str], list[str]]:
    """Check whether provenance exactly identifies the current patch set.

    This is separate from blob integrity: a legacy provenance file can be a
    truthful record of an old binary without matching today's patches.
    """
    errors: list[str] = []
    warnings: list[str] = []
    build = provenance.get("build", {})
    state = str(build.get("sourceState", ""))
    recorded = build.get("patchSha256", {})
    if not re.fullmatch(r"[0-9a-f]{64}", state) or not isinstance(recorded, dict) or not recorded:
        warnings.append(
            "patch freshness unverified: provenance has no exact sourceState and patchSha256"
        )
        return errors, warnings
    for name, data in patches.items():
        expected = recorded.get(name)
        if expected is None:
            errors.append(f"patch missing from provenance: {name}")
        elif not re.fullmatch(r"[0-9a-f]{64}", str(expected)):
            errors.append(f"build.patchSha256[{name}] is not a 64-hex digest")
        elif sha256(data) != expected:
            errors.append(f"patch sha256 mismatch: {name}")
    for name in recorded:
        if name not in patches:
            errors.append(f"provenance lists a patch that is missing: {name}")
    if any(not re.fullmatch(r"[0-9a-f]{64}", str(recorded[name])) for name in recorded):
        errors.append("build.patchSha256 has malformed digests")
    else:
        digest = sha256(b"".join(
            (name + "\n").encode() + bytes.fromhex(recorded[name])
            for name in sorted(recorded)
        ))
        if digest != state:
            errors.append("build.sourceState does not match build.patchSha256")
    command = str(build.get("command", ""))
    for flag in ("GOOS=windows", "GOARCH=amd64", "-trimpath", "-s -w", "-buildvcs=false"):
        if flag not in command:
            errors.append(f"build.command is missing {flag}")
    return errors, warnings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--require-current-patches",
        action="store_true",
        help="fail when provenance does not exactly identify the current patch set",
    )
    args = parser.parse_args(argv)

    if not PROVENANCE.is_file():
        print(f"missing provenance file: {PROVENANCE}", file=sys.stderr)
        return 1
    provenance = json.loads(PROVENANCE.read_text(encoding="utf-8"))

    compressed_meta = provenance["compressed"]
    compressed_path = RESOURCES / compressed_meta["file"]
    if not compressed_path.is_file():
        print(f"missing engine blob: {compressed_path}", file=sys.stderr)
        return 1
    compressed = compressed_path.read_bytes()
    check("compressed bytes", len(compressed), compressed_meta["bytes"])
    check("compressed sha256", sha256(compressed), compressed_meta["sha256"])

    try:
        payload = zlib.decompress(compressed)
    except zlib.error as exc:
        print(f"engine blob is not valid zlib: {exc}", file=sys.stderr)
        return 1
    payload_meta = provenance["payload"]
    check("payload bytes", len(payload), payload_meta["bytes"])
    check("payload sha256", sha256(payload), payload_meta["sha256"])

    commit = str(provenance.get("sourceCommit", ""))
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        ERRORS.append(f"sourceCommit is not a full 40-hex commit: {commit!r}")
    elif ENGINE_RS.is_file():
        match = re.search(r'ENGINE_VERSION:\s*&str\s*=\s*"([0-9a-f]+)"', ENGINE_RS.read_text(encoding="utf-8"))
        if not match:
            ERRORS.append("engine.rs: ENGINE_VERSION not found")
        else:
            check("engine.rs commit prefix", commit[: len(match.group(1))], match.group(1))

    for field in ("goModSha256", "goSumSha256"):
        value = str(provenance.get(field, ""))
        if not re.fullmatch(r"[0-9a-f]{64}", value):
            ERRORS.append(f"{field} is not a 64-hex digest")
    freshness_errors, freshness_warnings = check_current_patches(provenance, patch_files())
    if args.require_current_patches:
        ERRORS.extend(freshness_errors)
        ERRORS.extend(freshness_warnings)
    else:
        WARNINGS.extend(freshness_errors)
        WARNINGS.extend(freshness_warnings)

    if ERRORS:
        for error in ERRORS:
            print(f"error: {error}", file=sys.stderr)
        return 1
    for warning in WARNINGS:
        print(f"warning: {warning}", file=sys.stderr)
    print(
        "engine ok: "
        f"{compressed_meta['bytes']} compressed, "
        f"{payload_meta['bytes']} extracted, commit {commit[:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
