#!/bin/bash
# Native release acceptance checks for a built macOS app or DMG.
#
# This script only reports checks it can actually perform on the current Mac.
# It does not replace the manual clean-install/upgrade/soak checklist in
# docs/RELEASE_ACCEPTANCE.md, and a Chromium/mock smoke is never accepted as
# evidence here.
#
# Usage:
#   MacOS/scripts/native-acceptance.sh --app /path/to/MelonTools.app [options]
#   MacOS/scripts/native-acceptance.sh --dmg /path/to/MelonTools-X.Y.Z.dmg [options]
#
# Options:
#   --sha256 FILE       checksum file for the DMG (default: <dmg>.sha256)
#   --require-signed    fail unless the app and nested code are Developer ID
#                       signed, notarized and accepted by Gatekeeper
#   --launch            launch a temporary copy and verify the process stays up
#                       (opt-in; needs a GUI session)
#   --report FILE       also write the report to FILE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_SCRIPT="$ROOT/MacOS/scripts/fetch-runtime.sh"
APP=""
DMG=""
SHA_FILE=""
REQUIRE_SIGNED=0
LAUNCH=0
REPORT_FILE=""
MOUNT=""
LAUNCH_COPY=""
LAUNCH_PID=""
PASSED=0
FAILED=0
SKIPPED=0
MANUAL=0

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

cleanup() {
  if [ -n "${LAUNCH_PID:-}" ] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
    kill -TERM "$LAUNCH_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$LAUNCH_PID" 2>/dev/null || true
  fi
  if [ -n "${LAUNCH_COPY:-}" ] && [ -d "$LAUNCH_COPY" ]; then
    rm -rf -- "$LAUNCH_COPY"
  fi
  if [ -n "${MOUNT:-}" ] && [ -d "$MOUNT" ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rmdir "$MOUNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

record() {
  local line="$1"
  printf '%s\n' "$line"
  if [ -n "$REPORT_FILE" ]; then
    printf '%s\n' "$line" >> "$REPORT_FILE"
  fi
}
pass() { PASSED=$((PASSED + 1)); record "PASS    $*"; }
fail() { FAILED=$((FAILED + 1)); record "FAIL    $*"; }
skip() { SKIPPED=$((SKIPPED + 1)); record "SKIP    $*"; }
manual() { MANUAL=$((MANUAL + 1)); record "MANUAL  $*"; }
detail() { [ -n "$REPORT_FILE" ] && printf '        %s\n' "$*" >> "$REPORT_FILE" || true; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --sha256) SHA_FILE="${2:-}"; shift 2 ;;
    --require-signed) REQUIRE_SIGNED=1; shift ;;
    --launch) LAUNCH=1; shift ;;
    --report) REPORT_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [ -n "$APP" ] && [ -n "$DMG" ]; then
  echo "error: pass either --app or --dmg, not both" >&2
  exit 64
fi
if [ -z "$APP" ] && [ -z "$DMG" ]; then
  echo "error: pass --app or --dmg" >&2
  usage >&2
  exit 64
fi
for tool in codesign file hdiutil plutil shasum lipo otool; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: required tool not found: $tool" >&2; exit 2; }
done
[ -x "$RUNTIME_SCRIPT" ] || { echo "error: runtime checker not found: $RUNTIME_SCRIPT" >&2; exit 2; }
if [ -n "$REPORT_FILE" ]; then
  mkdir -p "$(dirname "$REPORT_FILE")"
  : > "$REPORT_FILE"
fi
record "Melon Tools native acceptance — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
record "host: $(sw_vers -productVersion) $(uname -m)"

if [ -n "$DMG" ]; then
  [ -f "$DMG" ] || { echo "error: DMG not found: $DMG" >&2; exit 2; }
  record "target: $DMG"
  if hdiutil verify "$DMG" >/dev/null 2>&1; then
    pass "DMG structure verifies (hdiutil verify)"
  else
    fail "DMG structure is damaged"
  fi
  MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/melon-acceptance.XXXXXX")"
  if hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null 2>&1; then
    pass "DMG attaches read-only"
  else
    fail "DMG does not attach"
    rmdir "$MOUNT" 2>/dev/null || true
    MOUNT=""
  fi
  APP="$MOUNT/Melon Tools.app"
  if [ -L "$MOUNT/Applications" ]; then
    pass "DMG contains the Applications link"
  else
    fail "DMG has no Applications link"
  fi
else
  record "target: $APP"
  if [ ! -d "$APP" ]; then
    fail "app bundle is missing: $APP"
    record ""
    record "acceptance: $PASSED passed, $FAILED failed, $SKIPPED skipped, $MANUAL manual"
    exit 1
  fi
  APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
fi

if [ -d "$APP" ]; then
  pass "app bundle exists"
else
  fail "app bundle is missing: $APP"
  echo "acceptance: $PASSED passed, $FAILED failed, $SKIPPED skipped, $MANUAL manual" >&2
  exit 1
fi

EXECUTABLE="$APP/Contents/MacOS/MelonTools"
if [ -x "$EXECUTABLE" ]; then
  pass "main executable is present and executable"
else
  fail "main executable is missing: $EXECUTABLE"
fi

if [ -f "$APP/Contents/Info.plist" ]; then
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ -n "$APP_VERSION" ]; then
    pass "Info.plist version: $APP_VERSION"
  else
    fail "Info.plist has no CFBundleShortVersionString"
  fi
  PROJECT_VERSION="$(awk -F'"' '/CFBundleShortVersionString:/{print $2; exit}' "$ROOT/MacOS/app/project.yml" 2>/dev/null || true)"
  if [ -n "$PROJECT_VERSION" ] && [ -n "$APP_VERSION" ] && [ "$APP_VERSION" != "$PROJECT_VERSION" ]; then
    fail "bundle version $APP_VERSION does not match project.yml $PROJECT_VERSION"
  fi
else
  fail "Info.plist is missing"
fi

SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  pass "app signature verifies (deep strict)"
else
  fail "app signature does not verify"
  detail "$SIGN_INFO"
fi
if printf '%s\n' "$SIGN_INFO" | grep -q 'Signature=adhoc'; then
  if [ "$REQUIRE_SIGNED" -eq 1 ]; then
    fail "app is ad-hoc signed (--require-signed)"
  else
    skip "app is ad-hoc signed; notarization cannot be checked"
  fi
else
  TEAM="$(printf '%s\n' "$SIGN_INFO" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if [ -n "$TEAM" ] && [ "$TEAM" != "not set" ]; then
    pass "app is Developer ID signed (team $TEAM)"
  else
    fail "app is not Developer ID signed"
  fi
  if [ "$REQUIRE_SIGNED" -eq 1 ]; then
    if spctl --assess --type execute --verbose=4 "$APP" >/dev/null 2>&1; then
      pass "Gatekeeper accepts the app (spctl --assess)"
    else
      fail "Gatekeeper rejects the app (spctl --assess)"
    fi
    if xcrun stapler validate "$APP" >/dev/null 2>&1; then
      pass "notarization ticket is stapled"
    else
      skip "no stapled ticket on the .app (the DMG may be stapled instead)"
    fi
    if [ -n "$DMG" ]; then
      if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
        pass "notarization ticket is stapled to the DMG"
      else
        fail "notarization ticket is not stapled to the DMG"
      fi
    fi
  fi
fi

NESTED=0
NESTED_BAD=0
while IFS= read -r -d '' candidate; do
  [ -f "$candidate" ] || continue
  file -b "$candidate" 2>/dev/null | grep -q 'Mach-O' || continue
  NESTED=$((NESTED + 1))
  if ! codesign --verify --strict "$candidate" >/dev/null 2>&1; then
    NESTED_BAD=$((NESTED_BAD + 1))
    detail "unsigned/invalid: $candidate"
  elif [ "$REQUIRE_SIGNED" -eq 1 ] \
       && ! codesign -dv --verbose=4 "$candidate" 2>&1 | grep -q 'Authority=Developer ID Application'; then
    NESTED_BAD=$((NESTED_BAD + 1))
    detail "not Developer ID signed: $candidate"
  fi
done < <(find "$APP/Contents" -type f -print0)
if [ "$NESTED" -eq 0 ]; then
  fail "no Mach-O files found inside the app"
elif [ "$NESTED_BAD" -eq 0 ]; then
  pass "all $NESTED nested Mach-O files have valid signatures"
else
  fail "$NESTED_BAD of $NESTED nested Mach-O files are unsigned or ad-hoc"
fi

RUNTIME="$APP/Contents/Resources/runtime"
if [ -d "$RUNTIME" ]; then
  if RUNTIME_DEST="$RUNTIME" "$RUNTIME_SCRIPT" --check >/dev/null 2>&1; then
    pass "bundled llama.cpp runtime is universal and its manifest digest matches"
  else
    fail "bundled llama.cpp runtime failed fetch-runtime.sh --check"
    RUNTIME_DEST="$RUNTIME" "$RUNTIME_SCRIPT" --check >&2 || true
  fi
else
  fail "bundled runtime is missing: $RUNTIME"
fi

GATEWAY="$APP/Contents/Resources/bin/cliproxyapi.gz"
GATEWAY_SHA="$APP/Contents/Resources/bin/cliproxyapi.sha256"
if [ -f "$GATEWAY" ] && [ -f "$GATEWAY_SHA" ]; then
  if gzip -t "$GATEWAY" >/dev/null 2>&1; then
    pass "embedded gateway gzip is intact"
  else
    fail "embedded gateway gzip is corrupt"
  fi
  EXPECTED="$(cut -d' ' -f1 "$GATEWAY_SHA" 2>/dev/null || true)"
  ACTUAL="$(gzip -dc "$GATEWAY" 2>/dev/null | shasum -a 256 | cut -d' ' -f1 || true)"
  if [ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ]; then
    pass "embedded gateway SHA-256 matches the uncompressed engine"
  else
    fail "embedded gateway SHA-256 does not match (expected '$EXPECTED', got '$ACTUAL')"
  fi
else
  fail "embedded gateway or its .sha256 is missing"
fi

if [ -n "$DMG" ]; then
  if [ -z "$SHA_FILE" ] && [ -f "$DMG.sha256" ]; then
    SHA_FILE="$DMG.sha256"
  fi
  if [ -n "$SHA_FILE" ]; then
    if [ ! -f "$SHA_FILE" ]; then
      fail "checksum file not found: $SHA_FILE"
    elif (cd "$(dirname "$SHA_FILE")" && shasum -a 256 -c "$(basename "$SHA_FILE")" >/dev/null 2>&1); then
      pass "DMG matches $(basename "$SHA_FILE")"
    else
      fail "DMG does not match $(basename "$SHA_FILE")"
    fi
  else
    skip "no DMG .sha256 sibling supplied"
  fi
fi

if [ "$LAUNCH" -eq 1 ] && [ -d "$APP" ]; then
  LAUNCH_COPY="$(mktemp -d "${TMPDIR:-/tmp}/melon-launch.XXXXXX")"
  if ditto "$APP" "$LAUNCH_COPY/Melon Tools.app" 2>/dev/null; then
    if open -na "$LAUNCH_COPY/Melon Tools.app" >/dev/null 2>&1; then
      sleep 8
      LAUNCH_PID="$(pgrep -f "$LAUNCH_COPY/Melon Tools.app/Contents/MacOS/MelonTools" | head -1 || true)"
      if [ -n "$LAUNCH_PID" ] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
        pass "temporary app copy launched and stayed up for 8 s"
        kill -TERM "$LAUNCH_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
          kill -0 "$LAUNCH_PID" 2>/dev/null || break
          sleep 1
        done
        if kill -0 "$LAUNCH_PID" 2>/dev/null; then
          fail "app did not exit after SIGTERM"
          kill -KILL "$LAUNCH_PID" 2>/dev/null || true
        else
          pass "app exited after SIGTERM"
        fi
        LAUNCH_PID=""
      else
        fail "temporary app copy did not stay running"
      fi
    else
      fail "could not launch the temporary app copy"
    fi
  else
    fail "could not copy the app for the launch test"
  fi
else
  manual "launch/quit and login-item behaviour (run with --launch on a GUI session)"
fi

manual "clean install, upgrade/rollback with an active model, interrupted download, full disk, detached storage, corrupt/newer schema, sleep/wake/logoff, tray soak"
manual "Windows: native installer/portable, WebView2 IPC, DPAPI migration, DPI 125/150/200, tray — see docs/RELEASE_ACCEPTANCE.md"

record ""
record "acceptance: $PASSED passed, $FAILED failed, $SKIPPED skipped, $MANUAL manual"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
record "native checks passed; manual checklist is still required for release sign-off"
