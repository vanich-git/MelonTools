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

echo "==> building pinned engine"
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
  CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
    go build -trimpath -ldflags "-s -w" -o "$TMP/cliproxyapi.exe" ./cmd/server
)

python3 - "$TMP/cliproxyapi.exe" "$TMP/cliproxyapi.exe.z" "$PROVENANCE" "$PACKED" "$WRITE" <<'PY'
import hashlib
import json
import pathlib
import sys
import zlib

payload_path, packed_path, provenance_path, target_path, write = sys.argv[1:6]
write = write == "1"
payload = pathlib.Path(payload_path).read_bytes()
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
