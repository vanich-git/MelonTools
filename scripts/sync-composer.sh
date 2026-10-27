#!/bin/bash
# Keep the two injected composer scripts identical to the canonical source.
#
#   scripts/sync-composer.sh          copy shared/composer-chips.js to both apps
#   scripts/sync-composer.sh --check  fail if either copy drifted
#
# The Windows Rust bridge embeds shared/composer-chips.js directly; the macOS
# bundle still needs a Resources copy, and the Windows copy is kept for the
# pre-existing include paths/third-party builds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/shared/composer-chips.js"
TARGETS=(
  "$ROOT/MacOS/app/Resources/composer-chips.js"
  "$ROOT/Windows/app/resources/composer-chips.js"
)
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

for target in "${TARGETS[@]}"; do
  if [ "$CHECK" = "1" ]; then
    cmp -s "$SRC" "$target" || {
      echo "composer drift: $target differs from shared/composer-chips.js" >&2
      echo "run scripts/sync-composer.sh" >&2
      exit 1
    }
  else
    cp "$SRC" "$target"
    echo "synced $target"
  fi
done
if [ "$CHECK" = "1" ]; then
  echo "composer scripts are in sync"
fi
