#!/bin/bash
# Apply the local QoS patches to the pinned CLIProxyAPI checkout. The source
# is a disposable checkout, so every fresh fetch/build must reapply them.
#
# "reverse --check" of a single patch cannot prove idempotency: later patches
# (0009) rewrite hunks introduced by earlier ones (0001), so 0001 looks
# unapplied on a fully patched tree, and a reverse check of 0009 can even
# succeed on 0001..0008. Instead we identify the exact applied prefix by
# replaying 1..k onto HEAD copies of the touched files in a private directory
# and comparing bytes with the vendor worktree. The worktree is only read
# while the set is classified, so a partially applied or inconsistent set
# fails without modifying it, and nothing is written into the vendor .git.
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
patches=()
for patch in "$PATCH_DIR"/*.patch; do
  # exFAT keeps an AppleDouble sidecar next to every file; it is not a patch.
  if [[ "$(basename "$patch")" == ._* ]]; then
    continue
  fi
  patches+=("$patch")
done
count="${#patches[@]}"
if [ "$count" -eq 0 ]; then
  echo "no engine patches found in $PATCH_DIR" >&2
  exit 1
fi

# Files touched by the set. Patches own their paths, so this list is all we
# need to classify the tree; unrelated edits elsewhere cannot break us.
touched="$(for patch in "${patches[@]}"; do
  sed -n 's|^+++ b/||p' "$patch"
done | LC_ALL=C sort -u)"
if [ -z "$touched" ]; then
  echo "cannot read patched paths from $PATCH_DIR" >&2
  exit 1
fi

# Private scratch space inside the project: candidate trees are plain files, so
# no git index, object database or worktree of the vendor is written to.
WORK="$(mktemp -d "$ROOT/.apply-engine-patches.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Apply into a plain directory. GIT_CEILING_DIRECTORIES stops git from picking
# up the enclosing MelonTools repository, keeping this a pure file operation.
apply_in() {
  GIT_CEILING_DIRECTORIES="$WORK" git -C "$1" apply "$2"
}

check_in() {
  GIT_CEILING_DIRECTORIES="$WORK" git -C "$1" apply --check "$2" >/dev/null 2>&1
}

# Snapshot of the committed versions of every touched file. Missing paths stay
# absent: the patch that creates them adds them during replay.
BASE="$WORK/base"
mkdir -p "$BASE"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if git -C "$SRC" cat-file -e "HEAD:$path" 2>/dev/null; then
    mkdir -p "$BASE/$(dirname "$path")"
    git -C "$SRC" show "HEAD:$path" > "$BASE/$path"
  fi
done <<< "$touched"

replay_prefix() {
  local dst="$1" upto="$2" i
  for ((i = 0; i < upto; i++)); do
    apply_in "$dst" "${patches[$i]}" || return 1
  done
}

matches_worktree() {
  local dst="$1" path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -e "$dst/$path" ] && [ -e "$SRC/$path" ]; then
      cmp -s "$dst/$path" "$SRC/$path" || return 1
    elif [ -e "$dst/$path" ] || [ -e "$SRC/$path" ]; then
      return 1
    fi
  done <<< "$touched"
  return 0
}

# Find the exact prefix 1..k that produced the current worktree. Comparing
# bytes, not hunks, keeps a partially applied set from being misclassified.
applied=-1
for ((k = count; k >= 0; k--)); do
  candidate="$WORK/candidate-$k"
  cp -R "$BASE" "$candidate"
  if replay_prefix "$candidate" "$k" && matches_worktree "$candidate"; then
    applied="$k"
    break
  fi
done

if [ "$applied" -lt 0 ]; then
  echo "engine patch set is in an inconsistent state under $SRC" >&2
  echo "the worktree matches no prefix of $PATCH_DIR; refusing to extend a partially applied set" >&2
  echo "restore the checkout and rerun" >&2
  exit 1
fi

if [ "$applied" -eq "$count" ]; then
  for patch in "${patches[@]}"; do
    echo "engine patch already applied: $(basename "$patch")"
  done
  exit 0
fi

# Rehearse the missing suffix on a copy of the worktree before touching vendor,
# so a conflicting set fails without leaving the worktree half patched.
TRIAL="$WORK/trial"
mkdir -p "$TRIAL"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -e "$SRC/$path" ] || continue
  mkdir -p "$TRIAL/$(dirname "$path")"
  cp -p "$SRC/$path" "$TRIAL/$path"
done <<< "$touched"
for ((i = applied; i < count; i++)); do
  patch="${patches[$i]}"
  if ! check_in "$TRIAL" "$patch"; then
    echo "engine patch set cannot be completed: $(basename "$patch") does not apply" >&2
    echo "expected patches 1..$applied to be applied; $SRC was not modified" >&2
    exit 1
  fi
  apply_in "$TRIAL" "$patch"
done

for ((i = applied; i < count; i++)); do
  patch="${patches[$i]}"
  git -C "$SRC" apply "$patch"
  echo "engine patch applied: $(basename "$patch")"
done
