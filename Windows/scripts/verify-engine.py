#!/usr/bin/env python3
"""Verify the embedded Windows gateway engine against its provenance file.

The Windows build embeds a prebuilt, compressed CLIProxyAPI binary. This
script makes the blob auditable without rebuilding it:

    python3 Windows/scripts/verify-engine.py

It checks the compressed bytes, the zlib payload, and the commit prefix that
engine.rs reports. Run it in CI and before a release.
"""

from __future__ import annotations

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


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        ERRORS.append(f"{label}: got {actual!r}, expected {expected!r}")


def main() -> int:
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
    command = str(provenance.get("build", {}).get("command", ""))
    for flag in ("GOOS=windows", "GOARCH=amd64", "-trimpath", "-s -w"):
        if flag not in command:
            ERRORS.append(f"build.command is missing {flag}")

    if ERRORS:
        for error in ERRORS:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(
        "engine ok: "
        f"{compressed_meta['bytes']} compressed, "
        f"{payload_meta['bytes']} extracted, commit {commit[:12]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
