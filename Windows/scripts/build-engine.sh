#!/bin/bash
# Rebuild the embedded Windows gateway engine from the pinned source and
# compare it with Windows/app/resources/engine-provenance.json.
#
#   Windows/scripts/build-engine.sh            # verify only
#   Windows/scripts/build-engine.sh --write    # replace the embedded blob
#
# The build is reproducible with Go 1.26.10: -trimpath, no VCS stamping by
# default (the source checkout is a git repo, so the VCS block is included),
# -ldflags "-s -w", then zlib level 9. The script uses the same dependency bump
# as MacOS/scripts/fetch-sources.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/MacOS/_sources/CLIProxyAPI"
RES="$ROOT/Windows/app/resources"
PROVENANCE="$RES/engine-provenance.json"
PACKED="$RES/cliproxyapi.exe.z"
WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1

if [ ! -d "$SRC" ]; then
  "$ROOT/MacOS/scripts/fetch-sources.sh"
fi

export GOTOOLCHAIN=go1.26.10
TMP="$(mktemp -d "${TMPDIR:-/tmp}/melon-engine.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

SOURCE_STATUS="$(git -C "$SRC" status --porcelain --untracked-files=normal)" || {
  echo "Cannot inspect engine source; refusing to reset or clean it." >&2
  exit 1
}

# A checkout prepared by MacOS/scripts/fetch-sources.sh is intentionally dirty:
# it carries the dependency bump plus every MacOS/patches/*.patch. That state is
# the one the embedded blob was built from, so rebuild it in place instead of
# resetting. Anything else in the tree is somebody's work, and is left alone.
EXPECTED_DIRTY=0
if [ -n "$SOURCE_STATUS" ]; then
  # `comm` only works when both inputs use the same collation, so every sort
  # below runs under LC_ALL=C. Mixing locales reports matching paths as
  # unexpected and blocks an otherwise valid build.
  CHANGED="$(printf '%s\n' "$SOURCE_STATUS" | cut -c4- | sed 's/.* -> //' | LC_ALL=C sort -u)"
  PATCHED="$(
    { for patch in "$ROOT"/MacOS/patches/*.patch; do
        git -C "$SRC" apply --numstat "$patch" 2>/dev/null | cut -f3
      done
      printf 'go.mod\ngo.sum\n'
    } | LC_ALL=C sort -u
  )"
  UNEXPECTED="$(LC_ALL=C comm -23 <(printf '%s\n' "$CHANGED") <(printf '%s\n' "$PATCHED"))"
  if [ -n "$UNEXPECTED" ]; then
    echo "Engine source has local changes outside the pinned patch set:" >&2
    printf '%s\n' "$UNEXPECTED" | sed 's/^/  /' >&2
    echo "Refusing to reset or clean it; commit or stash those files first." >&2
    exit 1
  fi
  for patch in "$ROOT"/MacOS/patches/*.patch; do
    if ! git -C "$SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
      echo "Engine source is missing $(basename "$patch"); run MacOS/scripts/fetch-sources.sh." >&2
      exit 1
    fi
  done
  if ! grep -q 'klauspost/compress v1.18.7' "$SRC/go.mod"; then
    echo "Engine source is missing the klauspost/compress bump; run MacOS/scripts/fetch-sources.sh." >&2
    exit 1
  fi
  EXPECTED_DIRTY=1
fi

# The provenance pins go.mod and go.sum as well, because the same commit built
# against a different dependency graph is not the same binary. verify-engine.py
# can only check the digest format: it runs without the engine sources. Here
# the tree is on disk, so compare the real bytes before spending minutes on a
# build that would silently produce a different engine.
check_dependencies() {
python3 - "$SRC" "$PROVENANCE" <<'PY'
import hashlib
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
provenance = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
failed = False
for field, name in (("goModSha256", "go.mod"), ("goSumSha256", "go.sum")):
    expected = provenance.get(field, "")
    path = src / name
    if not path.is_file():
        print(f"engine source is missing {name}", file=sys.stderr)
        failed = True
        continue
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        print(
            f"{name} does not match provenance: got {actual}, expected {expected}",
            file=sys.stderr,
        )
        failed = True
if failed:
    raise SystemExit("engine source does not match the pinned dependencies")
PY
}




if [ "$EXPECTED_DIRTY" = "0" ]; then
  (
    cd "$SRC"
    git checkout --quiet --force "$(python3 -c "import json;print(json.load(open('$PROVENANCE'))['sourceCommit'])")"
    # The QoS patch adds files that `git checkout` leaves untracked; remove them
    # so the patch can be applied to a clean tree instead of colliding with a
    # previous application.
    git clean --quiet -ffd
    GOTOOLCHAIN=go1.26.10 go get github.com/klauspost/compress@v1.18.7 >/dev/null
    GOTOOLCHAIN=go1.26.10 go mod tidy >/dev/null
    "$ROOT/MacOS/scripts/apply-engine-patches.sh"
  )
fi

# Checked after both preparation paths have settled the tree, so a stale or
# half-prepared checkout fails here instead of producing a different binary.
check_dependencies

echo "==> building pinned engine"
(
  cd "$SRC"
  CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
    go build -trimpath -ldflags "-s -w" -o "$TMP/cliproxyapi.exe" ./cmd/server
)

python3 - "$TMP/cliproxyapi.exe" "$TMP/cliproxyapi.exe.z" "$PROVENANCE" "$PACKED" "$WRITE" <<'PY'
import hashlib
import json
import pathlib
import struct
import sys
import zlib

payload_path, packed_path, provenance_path, target_path, write = sys.argv[1:6]
write = write == "1"
payload = pathlib.Path(payload_path).read_bytes()
if len(payload) < 64 or payload[:2] != b"MZ":
    raise SystemExit("Invalid gateway executable: missing DOS header")
pe_offset = struct.unpack_from("<I", payload, 0x3c)[0]
if pe_offset + 6 > len(payload) or payload[pe_offset:pe_offset + 4] != b"PE\0\0" or struct.unpack_from("<H", payload, pe_offset + 4)[0] != 0x8664:
    raise SystemExit("Invalid gateway executable: expected Windows x86_64 PE")
if b"integrate.api.nvidia.com" not in payload or b"NvidiaLimitedDo" not in payload:
    raise SystemExit("Gateway executable does not contain the NVIDIA request limiter")
packed = zlib.compress(payload, 9)
provenance = json.loads(pathlib.Path(provenance_path).read_text(encoding="utf-8"))


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


actual = {
    "payload": (len(payload), sha(payload)),
    "compressed": (len(packed), sha(packed)),
}
expected = {
    "payload": (provenance["payload"]["bytes"], provenance["payload"]["sha256"]),
    "compressed": (provenance["compressed"]["bytes"], provenance["compressed"]["sha256"]),
}
for label in ("payload", "compressed"):
    if actual[label] != expected[label]:
        print(
            f"engine mismatch ({label}): got {actual[label]}, "
            f"expected {expected[label]}",
            file=sys.stderr,
        )
        if not write:
            raise SystemExit(1)
if write:
    pathlib.Path(target_path).write_bytes(packed)
    print(f"engine written: {target_path} ({len(packed)} bytes)")
else:
    print(f"engine reproducible: {len(packed)} compressed, {len(payload)} extracted")
PY
