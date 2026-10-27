#!/bin/bash
# Read-only repository health check (REL-14 / X1).
#
# Detects the exFAT failure modes without deleting anything:
#   - AppleDouble `._*` sidecars anywhere in the worktree or .git objects;
#   - git's "non-monotonic index" warnings from `._*.idx`;
#   - tracked files that are unexpectedly executable.
#
# Usage: scripts/doctor.sh [repo-root]
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

problems=0
note() { printf '  %s\n' "$*"; }
fail() { problems=$((problems + 1)); printf 'FAIL: %s\n' "$*"; }

echo "==> filesystem"
MOUNT_POINT="$(df . 2>/dev/null | awk 'NR==2 {print $NF}' || true)"
if mount 2>/dev/null | grep -F " on ${MOUNT_POINT:-/} " | grep -qi 'exfat'; then
  fail "worktree is on exFAT; keep the checkout on APFS (see specs/improvement-audit-2026-10-27.md X1)"
else
  note "worktree mount: ${MOUNT_POINT:-unknown}"
fi

echo "==> AppleDouble sidecars"
SIDECARS="$(find . -name '._*' -not -path './.git/*' -print 2>/dev/null | head -20 || true)"
if [ -n "$SIDECARS" ]; then
  fail "AppleDouble files found (run dot_clean . on a copy, never blindly):"
  printf '%s\n' "$SIDECARS" | sed 's/^/    /'
else
  note "none"
fi

GIT_SIDECARS="$(find .git/objects -name '._*.idx' -o -name '._*.pack' 2>/dev/null | head -20 || true)"
if [ -n "$GIT_SIDECARS" ]; then
  fail "AppleDouble files inside .git/objects:"
  printf '%s\n' "$GIT_SIDECARS" | sed 's/^/    /'
else
  note "git objects clean"
fi

echo "==> git integrity"
GIT_LOG="$(git status --short 2>&1 >/dev/null || true)"
if printf '%s' "$GIT_LOG" | grep -q 'non-monotonic index'; then
  fail "git reports non-monotonic index; remove only ._*.idx files from .git/objects/pack"
else
  note "no non-monotonic index warning"
fi

echo "==> executable bits"
# Shell, Python and JS release tooling should be executable; sources should
# not carry +x. Check the worktree: core.filemode is off on the exFAT repo, so
# the index mode is not trustworthy.
BAD_MODE="$(git ls-files 2>/dev/null | while IFS= read -r file; do
  [ -f "$file" ] || continue
  [ -x "$file" ] || continue
  printf '%s\n' "$file"
done | grep -Ev '\.(sh|py|js|plist)$' | head -20 || true)"
if [ -n "$BAD_MODE" ]; then
  fail "unexpected executable files:"
  printf '%s\n' "$BAD_MODE" | sed 's/^/    /'
else
  note "no unexpected executable files"
fi

if [ "$problems" -gt 0 ]; then
  echo "doctor: $problems problem(s)" >&2
  exit 1
fi
echo "doctor: OK"
