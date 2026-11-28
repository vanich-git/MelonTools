#!/bin/bash
# Rebuild the embedded Windows gateway engine from the pinned source and
# compare it with Windows/app/resources/engine-provenance.json.
#
#   Windows/scripts/build-engine.sh            # build and verify
#   Windows/scripts/build-engine.sh --write    # replace the embedded blob
#
# The source is prepared in a private clone under the project: the vendored
# checkout is never reset, cleaned or modified. The build uses Go 1.26.10 with
# -trimpath and -buildvcs=false, then zlib level 9.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/MacOS/_sources/CLIProxyAPI"
RES="$ROOT/Windows/app/resources"
PROVENANCE="$RES/engine-provenance.json"
WRITE=0
if [ $# -gt 1 ] || { [ $# -eq 1 ] && [ "$1" != "--write" ]; }; then
  echo "usage: $0 [--write]" >&2
  exit 2
fi
[ "${1:-}" = "--write" ] && WRITE=1

for tool in git python3 go; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done
[ -f "$PROVENANCE" ] || { echo "missing provenance: $PROVENANCE" >&2; exit 1; }

COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceCommit"])' "$PROVENANCE")"
GO_TOOLCHAIN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["goToolchain"])' "$PROVENANCE")"

# Keep scratch inside the project. Nothing is written into the vendor tree.
TEMP_ROOT="$ROOT/Windows/.build-engine"
mkdir -p "$TEMP_ROOT"
TMP="$(mktemp -d "$TEMP_ROOT/work.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CHECKOUT="$TMP/source"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# Keep Go caches, module downloads, toolchains and temporary files in the
# project. No cache is written into the home directory or the OS temp dir.
export HOME="$TMP/home"
export TMPDIR="$TMP"
export GOCACHE="$TMP/gocache"
export GOMODCACHE="$TMP/gomodcache"
export GOPATH="$TMP/gopath"
mkdir -p "$HOME" "$GOCACHE" "$GOMODCACHE" "$GOPATH"

if [ -d "$SRC/.git" ] || [ -f "$SRC/.git" ]; then
  git clone --quiet --shared "$SRC" "$CHECKOUT"
else
  # CI has no vendored checkout: fetch the exact pinned commit from upstream.
  git clone --quiet --no-checkout https://github.com/router-for-me/CLIProxyAPI.git "$CHECKOUT"
fi
git -C "$CHECKOUT" checkout --quiet --force "$COMMIT"
expected_head="$(git -C "$SRC" rev-parse "$COMMIT" 2>/dev/null || printf '%s' "$COMMIT")"
[ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$expected_head" ] || {
  echo "engine checkout does not match the pinned commit" >&2
  exit 1
}

# Prepare dependencies in the isolated checkout, then apply the exact patch set.
(
  cd "$CHECKOUT"
  GOTOOLCHAIN="$GO_TOOLCHAIN" go get github.com/klauspost/compress@v1.18.7 >/dev/null
  GOTOOLCHAIN="$GO_TOOLCHAIN" go mod tidy >/dev/null
)
# apply-engine-patches.sh classifies the checkout by replaying patches in a
# private directory and never resets or cleans anything.
"$ROOT/MacOS/scripts/apply-engine-patches.sh" "$CHECKOUT" >/dev/null

# Immutable facts (pinned commit, dependency digests) must always match.
# An older provenance file may not record exact patch hashes; in verify mode
# that state is reported as unverified, in --write mode we replace it.
python3 - "$ROOT" "$CHECKOUT" "$PROVENANCE" "$WRITE" <<'PY'
import hashlib
import json
import pathlib
import sys

root, checkout, provenance_path, write_flag = sys.argv[1:5]
write = write_flag == "1"
provenance = json.loads(pathlib.Path(provenance_path).read_text(encoding="utf-8"))
errors = []
notes = []
build = provenance.get("build", {})
state = str(build.get("sourceState", ""))
recorded = build.get("patchSha256", {})
if not write:
    if not isinstance(recorded, dict) or not recorded:
        notes.append("patch freshness unverified: no exact patchSha256 in provenance")
    else:
        patterns = sorted((root / "MacOS/patches").glob("[0-9]*.patch"))
        names = sorted(recorded)
        if names != [p.name for p in patterns]:
            errors.append("patch set differs from provenance")
        else:
            for p in patterns:
                if hashlib.sha256(p.read_bytes()).hexdigest() != recorded[p.name]:
                    errors.append(f"{p.name}: sha256 mismatch")
            if any(not isinstance(recorded[name], str) or not __import__("re").fullmatch(r"[0-9a-f]{64}", recorded[name]) for name in names):
                errors.append("build.patchSha256 has malformed digests")
            else:
                digest = hashlib.sha256(b"".join(
                    (name + "\n").encode() + bytes.fromhex(recorded[name]) for name in names
                )).hexdigest()
                if state and digest != state:
                    errors.append("build.sourceState does not match build.patchSha256")
for note in notes:
    print(f"warning: {note}", file=sys.stderr)
for field, name in (("goModSha256", "go.mod"), ("goSumSha256", "go.sum")):
    expected = str(provenance.get(field, ""))
    path = checkout / name
    if not path.is_file():
        errors.append(f"isolated checkout is missing {name}")
    else:
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            errors.append(f"{name}: got {actual}, expected {expected}")
if errors:
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    raise SystemExit(1)
PY

echo "==> building pinned engine"
(
  cd "$CHECKOUT"
  CGO_ENABLED=0 GOOS=windows GOARCH=amd64 GOTOOLCHAIN="$GO_TOOLCHAIN" \
    go build -trimpath -buildvcs=false -ldflags "-s -w" -o "$BUILD_DIR/cliproxyapi.exe" ./cmd/server
)

python3 - "$BUILD_DIR/cliproxyapi.exe" "$BUILD_DIR/cliproxyapi.exe.z" "$PROVENANCE" "$WRITE" <<'PY'
import hashlib
import json
import pathlib
import struct
import sys
import zlib

payload_path, packed_path, provenance_path, write_flag = sys.argv[1:5]
write = write_flag == "1"
payload = pathlib.Path(payload_path).read_bytes()
if len(payload) < 0x1000 or payload[:2] != b"MZ":
    raise SystemExit("invalid gateway executable: missing DOS header")
e_lfanew = struct.unpack_from("<I", payload, 0x3C)[0]
if e_lfanew < 0x40 or e_lfanew + 24 > len(payload) or payload[e_lfanew:e_lfanew + 4] != b"PE\0\0":
    raise SystemExit("invalid gateway executable: missing PE header")
machine, sections = struct.unpack_from("<HH", payload, e_lfanew + 4)
if machine != 0x8664 or not 1 <= sections <= 96:
    raise SystemExit("invalid gateway executable: expected Windows x86_64 PE")
opt_size = struct.unpack_from("<H", payload, e_lfanew + 20)[0]
opt = e_lfanew + 24
if opt_size < 112 or opt + opt_size > len(payload):
    raise SystemExit("invalid gateway executable: truncated optional header")
magic = struct.unpack_from("<H", payload, opt)[0]
if magic != 0x20B:
    raise SystemExit("invalid gateway executable: expected PE32+ optional header")
section_align, file_align = struct.unpack_from("<II", payload, opt + 32)
size_of_image, size_of_headers = struct.unpack_from("<II", payload, opt + 56)
checksum = struct.unpack_from("<I", payload, opt + 64)[0]
subsystem = struct.unpack_from("<H", payload, opt + 68)[0]
entry = struct.unpack_from("<I", payload, opt + 16)[0]
if section_align != 0x1000 or file_align != 0x200:
    raise SystemExit("invalid gateway executable: unexpected alignment")
if size_of_headers < 0x200 or size_of_headers > len(payload):
    raise SystemExit("invalid gateway executable: invalid SizeOfHeaders")
if size_of_image < size_of_headers or size_of_image > 0x80000000:
    raise SystemExit("invalid gateway executable: invalid SizeOfImage")
if checksum != 0:
    raise SystemExit("invalid gateway executable: unexpected PE checksum")
if subsystem not in (2, 3):
    raise SystemExit("invalid gateway executable: unexpected subsystem")
if entry == 0 or entry >= size_of_image:
    raise SystemExit("invalid gateway executable: invalid entry point")
section_table = opt + opt_size
if section_table + sections * 40 > len(payload):
    raise SystemExit("invalid gateway executable: truncated section table")
code_bytes = 0
for index in range(sections):
    base = section_table + index * 40
    virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from("<IIII", payload, base + 8)
    characteristics = struct.unpack_from("<I", payload, base + 36)[0]
    if raw_size == 0 or raw_pointer == 0:
        continue
    if raw_pointer % file_align or raw_pointer + raw_size > len(payload):
        raise SystemExit("invalid gateway executable: invalid section range")
    if virtual_address % section_align or virtual_address + max(virtual_size, raw_size) > size_of_image + section_align:
        raise SystemExit("invalid gateway executable: invalid section layout")
    if characteristics & 0x20000000:
        code_bytes += raw_size
if code_bytes < 0x10000:
    raise SystemExit("invalid gateway executable: no substantial code section")
if b"integrate.api.nvidia.com" not in payload or b"NvidiaLimitedDo" not in payload:
    raise SystemExit("gateway executable does not contain the NVIDIA request limiter")

def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

compressed = zlib.compress(payload, 9)
if zlib.decompress(compressed) != payload:
    raise SystemExit("compressed gateway does not round-trip")
# Zero-heavy corruption is visible in both the raw payload and the compressed
# stream. These are heuristics; the sha256 comparison below is authoritative.
payload_zeros = payload.count(0) / len(payload)
compressed_zeros = compressed.count(0) / len(compressed)
if payload_zeros > 0.75 or compressed_zeros > 0.20:
    raise SystemExit("suspicious zero-heavy gateway payload")

provenance = json.loads(pathlib.Path(provenance_path).read_text(encoding="utf-8"))
actual = {
    "payload": (len(payload), sha(payload)),
    "compressed": (len(compressed), sha(compressed)),
}
expected = {
    "payload": (provenance["payload"]["bytes"], provenance["payload"]["sha256"]),
    "compressed": (provenance["compressed"]["bytes"], provenance["compressed"]["sha256"]),
}
for label in ("payload", "compressed"):
    if actual[label] != expected[label]:
        print(
            f"engine mismatch ({label}): got {actual[label]}, expected {expected[label]}",
            file=sys.stderr,
        )
        if not write:
            raise SystemExit(1)
if write:
    pathlib.Path(packed_path).write_bytes(compressed)
    print(f"engine staged: {packed_path} ({len(compressed)} bytes)")
else:
    print(f"engine reproducible: {len(compressed)} compressed, {len(payload)} extracted")
PY

if [ "$WRITE" -eq 1 ]; then
  # Stage both files, replace the blob first and provenance second, and attempt
  # rollback on errors. A crash between replacements can leave a mismatched
  # pair, which verify-engine.py detects on the next verification.
  python3 - "$PROVENANCE" "$ROOT" "$BUILD_DIR/cliproxyapi.exe" "$BUILD_DIR/cliproxyapi.exe.z" "$RES/cliproxyapi.exe.z" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

provenance_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
payload_path = pathlib.Path(sys.argv[3])
compressed_path = pathlib.Path(sys.argv[4])
target_path = pathlib.Path(sys.argv[5])
original_provenance = provenance_path.read_bytes()
original_blob = target_path.read_bytes() if target_path.exists() else None
provenance = json.loads(original_provenance)
payload = payload_path.read_bytes()
compressed = compressed_path.read_bytes()

def sha(data):
    return hashlib.sha256(data).hexdigest()

patterns = sorted((root / "MacOS/patches").glob("[0-9]*.patch"))
by_name = {p.name: sha(p.read_bytes()) for p in patterns}
provenance["build"]["command"] = "CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -buildvcs=false -ldflags \"-s -w\" -o <out> ./cmd/server"
provenance["build"]["sourceState"] = sha(b"".join(
    (name + "\n").encode() + bytes.fromhex(by_name[name]) for name in sorted(by_name)
))
provenance["build"]["patchSha256"] = by_name
provenance["build"]["sourceStateAlgorithm"] = "sha256(concat(name + \"\\n\" + patchSha256))"
provenance["payload"] = {
    "file": "cliproxyapi.exe",
    "bytes": len(payload),
    "sha256": sha(payload),
}
provenance["compressed"] = {
    "file": "cliproxyapi.exe.z",
    "bytes": len(compressed),
    "sha256": sha(compressed),
}
updated = json.dumps(provenance, indent=2, ensure_ascii=False) + "\n"
staged_provenance = provenance_path.with_suffix(provenance_path.suffix + ".tmp")
staged_blob = target_path.with_suffix(target_path.suffix + ".tmp")
staged_provenance.write_text(updated, encoding="utf-8")
staged_blob.write_bytes(compressed)
try:
    os.replace(staged_blob, target_path)
    os.replace(staged_provenance, provenance_path)
except BaseException:
    staged_blob.unlink(missing_ok=True)
    staged_provenance.unlink(missing_ok=True)
    if original_blob is None:
        target_path.unlink(missing_ok=True)
    else:
        target_path.write_bytes(original_blob)
    provenance_path.write_bytes(original_provenance)
    raise
PY
fi
