#!/bin/bash
# Proves the REL-01 ordering rule on a clean tree: the pinned llama.cpp
# runtime must be fetched and verified BEFORE the first `xcodegen generate`.
#
# The runtime directory is gitignored, so a fresh checkout has no
# app/Resources/runtime. project.yml declares it as a folder source; XcodeGen
# fails while it is missing. This script:
#
#   1. copies the working tree into a temporary directory without the ignored
#      runtime, build products and the generated .xcodeproj;
#   2. asserts XcodeGen really fails on that tree (fixture is genuinely clean);
#   3. runs MacOS/scripts/fetch-runtime.sh, which downloads/merges/verifies the
#      pinned runtime;
#   4. generates the project again and checks the generated file and the
#      runtime manifest.
#
# It reuses RUNTIME_CACHE when set (CI populates MacOS/build/runtime-cache in
# the step before), otherwise downloads the pinned archives.
#
# Usage:
#   MacOS/scripts/test-clean-checkout.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/melon-clean-checkout.XXXXXX")"
COPY="$TMP/repo"
FAILED=0
PASSED=0
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

fail() { echo "  FAIL  $*" >&2; FAILED=$((FAILED + 1)); }
pass() { echo "  ok    $*"; PASSED=$((PASSED + 1)); }

command -v rsync >/dev/null 2>&1 || { echo "error: rsync not found" >&2; exit 2; }
command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found" >&2; exit 2; }

echo "==> copying a clean working tree (runtime excluded)"
mkdir -p "$COPY/MacOS"
rsync -a \
  --exclude 'build/' \
  --exclude '_sources/' \
  --exclude 'app/MelonTools.xcodeproj/' \
  --exclude 'app/Resources/runtime/' \
  --exclude '.DS_Store' \
  --exclude '._*' \
  "$ROOT/MacOS/" "$COPY/MacOS/"
# project.yml embeds this helper as a resource; keep the path layout identical.
[ -f "$COPY/MacOS/scripts/fetch-runtime.sh" ] || { echo "error: fixture is incomplete" >&2; exit 2; }

if [ -e "$COPY/MacOS/app/Resources/runtime" ]; then
  fail "fixture still contains Resources/runtime"
else
  pass "fixture has no Resources/runtime"
fi

echo "==> xcodegen must fail before the runtime exists"
if (cd "$COPY/MacOS/app" && xcodegen generate >/dev/null 2>"$TMP/pre.log"); then
  fail "xcodegen generated a project without Resources/runtime; project.yml no longer requires it"
else
  if grep -q 'missing source directory' "$TMP/pre.log"; then
    pass "xcodegen fails with the expected missing-source error"
  else
    fail "xcodegen failed for an unexpected reason"
    sed 's/^/    /' "$TMP/pre.log" >&2
  fi
fi

echo "==> fetch and verify the pinned runtime"
if [ -z "${RUNTIME_CACHE:-}" ]; then
  export RUNTIME_CACHE="$ROOT/MacOS/build/runtime-cache"
fi
if "$COPY/MacOS/scripts/fetch-runtime.sh" >"$TMP/fetch.log" 2>&1; then
  pass "fetch-runtime.sh completed"
else
  fail "fetch-runtime.sh failed"
  sed 's/^/    /' "$TMP/fetch.log" >&2
fi
if "$COPY/MacOS/scripts/fetch-runtime.sh" --check >/dev/null 2>&1; then
  pass "fetch-runtime.sh --check accepts the fetched runtime"
else
  fail "fetch-runtime.sh --check rejects the fetched runtime"
fi

echo "==> xcodegen after the runtime is present"
if (cd "$COPY/MacOS/app" && xcodegen generate >"$TMP/gen.log" 2>&1); then
  pass "xcodegen generated the project"
else
  fail "xcodegen still failed after the runtime was fetched"
  sed 's/^/    /' "$TMP/gen.log" >&2
fi
if [ -f "$COPY/MacOS/app/MelonTools.xcodeproj/project.pbxproj" ]; then
  pass "project.pbxproj exists"
else
  fail "project.pbxproj is missing"
fi

echo
echo "==> $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
