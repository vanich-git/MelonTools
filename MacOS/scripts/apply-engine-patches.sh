#!/bin/bash
# Apply the local QoS patches to the pinned CLIProxyAPI checkout. The source
# is a disposable checkout, so every fresh fetch/build must reapply them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/_sources/CLIProxyAPI}"
PATCH_DIR="$ROOT/patches"

# A linked worktree has no .git directory: .git is a file pointing at the
# real git dir. Ask git instead of probing the path.
if [ ! -d "$SRC" ] || ! git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
  echo "engine source is missing: $SRC" >&2
  exit 1
fi
shopt -s nullglob
for patch in "$PATCH_DIR"/*.patch; do
  # exFAT keeps an AppleDouble sidecar next to every file; it is not a patch.
  if [[ "$(basename "$patch")" == ._* ]]; then
    continue
  fi
  if git -C "$SRC" apply --reverse --check "$patch" >/dev/null 2>&1; then
    echo "engine patch already applied: $(basename "$patch")"
    continue
  fi
  git -C "$SRC" apply "$patch"
  echo "engine patch applied: $(basename "$patch")"
done
