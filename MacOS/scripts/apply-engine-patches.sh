#!/bin/bash
# Apply the local QoS patches to the pinned CLIProxyAPI checkout. The source
# is a disposable checkout, so every fresh fetch/build must reapply them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/_sources/CLIProxyAPI"
PATCH_DIR="$ROOT/patches"

if [ ! -d "$SRC/.git" ]; then
  echo "engine source is missing: $SRC" >&2
  exit 1
fi
shopt -s nullglob
for patch in "$PATCH_DIR"/*.patch; do
  if git -C "$SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "engine patch already applied: $(basename "$patch")"
    continue
  fi
  git -C "$SRC" apply "$patch"
  echo "engine patch applied: $(basename "$patch")"
done
