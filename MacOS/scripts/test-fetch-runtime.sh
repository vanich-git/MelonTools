#!/bin/bash
# Exercises scripts/fetch-runtime.sh without touching the shipped runtime.
#
#   scripts/test-fetch-runtime.sh          full run (rebuilds in a sandbox)
#   scripts/test-fetch-runtime.sh --quick  verify the bundled runtime only
#
# The sandbox reuses the download cache, so a full run is a local lipo/codesign
# pass unless the archives are missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FETCH="$ROOT/scripts/fetch-runtime.sh"
SHIPPED="$ROOT/app/Resources/runtime"
CACHE="$ROOT/build/runtime-cache"
QUICK=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

FAILED=0
PASSED=0
fail() { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
pass() { echo "  ok    $*"; PASSED=$((PASSED + 1)); }
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

archs() { lipo -archs "$1" 2>/dev/null || true; }
has() { case " $(archs "$1") " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
universal() { has "$1" arm64 && has "$1" x86_64; }
platform_is() { [ "$(sed -n 's/.*"platform":[[:space:]]*"\([^"]*\)".*/\1/p' "$1")" = "$2" ]; }
digest_matches() {
  local expected
  expected="$(sed -n 's/.*"sha256":[[:space:]]*"\([^"]*\)".*/\1/p' "$1/runtime.json")"
  [ "$expected" = "$(shasum -a 256 "$1/llama-server" | cut -d' ' -f1)" ]
}
universal_dylib_count() {
  local n=0 f a
  for f in "$1"/*.dylib; do
    case "${f##*/}" in ._*|*metal*) continue ;; esac
    a=" $(archs "$f") "
    case "$a" in *" arm64 "*) ;; *) continue ;; esac
    case "$a" in *" x86_64 "*) ;; *) continue ;; esac
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}
# Every @rpath dependency of every slice must be present in the folder and carry
# that slice: this is what makes the bundle self-contained per architecture.
closure_ok() {
  local dir="$1" f a dep n
  for f in "$dir"/llama-server "$dir"/*.dylib; do
    case "${f##*/}" in ._*) continue ;; esac
    for a in $(archs "$f"); do
      for dep in $(otool -arch "$a" -L "$f" | tail -n +2 \
                     | sed 's/^[[:space:]]*//' | awk '{print $1}' | grep '^@rpath/'); do
        n="${dep#@rpath/}"
        [ -f "$dir/$n" ] || return 1
        has "$dir/$n" "$a" || return 1
      done
    done
  done
}
no_metal_dep() { [ "$(otool -arch x86_64 -L "$1/llama-server" | grep -c metal || true)" -eq 0 ]; }
no_leftovers() { ! find "$1" -maxdepth 1 \( -name 'runtime.new.*' -o -name 'runtime.old.*' \) | grep -q .; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/melon-runtime-test.XXXXXX")"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

echo "==> bundled runtime"
if "$FETCH" --check >/dev/null 2>&1; then
  pass "fetch-runtime.sh --check accepts the bundled runtime"
else
  fail "fetch-runtime.sh --check rejects the bundled runtime"
fi
check "llama-server is a two-slice binary" universal "$SHIPPED/llama-server"
check "manifest declares macos-universal" platform_is "$SHIPPED/runtime.json" macos-universal

echo "==> safety guards"
mkdir -p "$TMP/guards/real"
if RUNTIME_DEST="$TMP/guards/absent/runtime" "$FETCH" --check >/dev/null 2>&1; then
  fail "--check accepts a missing runtime"
else
  pass "--check rejects a missing runtime"
fi
ln -s "$TMP/guards/real" "$TMP/guards/runtime"
if RUNTIME_DEST="$TMP/guards/runtime" "$FETCH" --check >/dev/null 2>&1; then
  fail "accepts a symlinked runtime folder"
else
  pass "refuses a symlinked runtime folder"
fi
if RUNTIME_DEST="$TMP/guards/real" "$FETCH" --check >/dev/null 2>&1; then
  fail "accepts a folder that is not named runtime"
else
  pass "refuses a folder that is not named 'runtime'"
fi

if [ "$QUICK" -eq 1 ]; then
  echo "==> $PASSED passed, $FAILED failed (quick)"
  [ "$FAILED" -eq 0 ]
  exit
fi

SANDBOX="$TMP/sandbox"
mkdir -p "$SANDBOX/cache" "$SANDBOX/runtime"
cp "$CACHE"/llama-*-bin-macos-*.tar.gz "$SANDBOX/cache/" 2>/dev/null || true
if [ ! -f "$SANDBOX/cache/llama-b12099-bin-macos-x64.tar.gz" ]; then
  echo "missing cached archives in $CACHE — run scripts/fetch-runtime.sh first" >&2
  exit 2
fi
export RUNTIME_CACHE="$SANDBOX/cache"
export RUNTIME_DEST="$SANDBOX/runtime"

echo "==> sandbox: build from an empty folder"
if "$FETCH" >"$TMP/build.log" 2>&1; then
  pass "fresh build"
else
  fail "fresh build (see output below)"
  cat "$TMP/build.log"
fi
check "llama-server has both slices" universal "$RUNTIME_DEST/llama-server"
check "32 shared dylibs are universal" [ "$(universal_dylib_count "$RUNTIME_DEST")" -eq 32 ]
check "Metal dylibs stay arm64-only and are not linked by the Intel slice" \
  no_metal_dep "$RUNTIME_DEST"
check "sandbox manifest declares macos-universal" platform_is "$RUNTIME_DEST/runtime.json" macos-universal
check "every rpath dependency resolves in the folder" closure_ok "$RUNTIME_DEST"

echo "==> sandbox: stale arm64-only runtime must be replaced"
ARM_SERVER="$(find "$CACHE/b12099/arm64" -type f -name llama-server -not -name '._*' -print -quit)"
cp "$ARM_SERVER" "$RUNTIME_DEST/llama-server"
if ! has "$RUNTIME_DEST/llama-server" x86_64; then
  pass "sandbox now looks like the old arm64-only runtime"
else
  fail "could not make the sandbox runtime arm64-only"
fi
if "$FETCH" --check >/dev/null 2>&1; then
  fail "--check accepts an arm64-only runtime"
else
  pass "--check rejects an arm64-only runtime"
fi
if "$FETCH" >"$TMP/replace.log" 2>&1; then
  pass "stale runtime rebuilt"
else
  fail "stale runtime rebuild"
  cat "$TMP/replace.log"
fi
check "runtime is universal again" universal "$RUNTIME_DEST/llama-server"
check "digest in the manifest matches the rebuilt binary" digest_matches "$RUNTIME_DEST"
check "no staging leftovers next to the runtime" no_leftovers "$SANDBOX"

echo "==> sandbox: refresh the manifest after a re-sign"
sed -i '' -E 's/"sha256": "[^"]*"/"sha256": "deadbeef"/' "$RUNTIME_DEST/runtime.json"
printf 'deadbeef  llama-server\n' > "$RUNTIME_DEST/runtime.sha256"
if "$FETCH" --check >/dev/null 2>&1; then
  fail "--check accepts a stale digest"
else
  pass "--check rejects a stale digest"
fi
if "$FETCH" --check --refresh-manifest >/dev/null 2>&1; then
  fail "accepts --check and --refresh-manifest together"
else
  pass "refuses conflicting --check/--refresh-manifest"
fi
if "$FETCH" --refresh-manifest >"$TMP/refresh.log" 2>&1; then
  pass "--refresh-manifest rewrites the digest without a rebuild"
else
  fail "--refresh-manifest failed"
  cat "$TMP/refresh.log"
fi
check "refreshed digest matches the binary" digest_matches "$RUNTIME_DEST"
check "refreshed runtime.sha256 matches the binary" \
  [ "$(cut -d' ' -f1 "$RUNTIME_DEST/runtime.sha256")" = \
    "$(shasum -a 256 "$RUNTIME_DEST/llama-server" | cut -d' ' -f1)" ]
check "refreshed runtime passes --check" "$FETCH" --check

echo "==> sandbox: failed download must not damage the installed runtime"
cp "$ARM_SERVER" "$RUNTIME_DEST/llama-server"
BEFORE="$(shasum -a 256 "$RUNTIME_DEST/llama-server" | cut -d' ' -f1)"
printf 'corrupt' | dd of="$SANDBOX/cache/llama-b12099-bin-macos-x64.tar.gz" bs=1 seek=64 conv=notrunc 2>/dev/null
if http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
   "$FETCH" >"$TMP/fail.log" 2>&1; then
  fail "build succeeded with a corrupt archive and no network"
else
  pass "build fails instead of installing a bad runtime"
fi
check "installed llama-server is untouched" \
  [ "$(shasum -a 256 "$RUNTIME_DEST/llama-server" | cut -d' ' -f1)" = "$BEFORE" ]
check "no staging leftovers after the failure" no_leftovers "$SANDBOX"

echo
echo "==> $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
