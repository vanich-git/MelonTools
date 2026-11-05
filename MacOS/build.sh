#!/bin/bash
# Melon Tools — one-shot build: gateway engine → icon → app → ad-hoc sign → dmg.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

# One composer script for both platforms; keep the bundle copy in sync.
"$ROOT/../scripts/sync-composer.sh" >/dev/null

# v8.0.44 requires Go 1.26.10 (the x509 advisory is fixed there). Pinning the
# toolchain also prevents a newer local Go from silently building with an
# older patch level.
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.26.10}"

# Single source of truth for the release version: app/project.yml.
VERSION="$(awk -F'"' '/CFBundleShortVersionString:/{print $2; exit}' app/project.yml)"
if [ -z "${VERSION:-}" ]; then
  echo "could not read CFBundleShortVersionString from app/project.yml" >&2
  exit 1
fi
echo "==> release version: $VERSION"

echo "==> 1/6 gateway engine (CLIProxyAPI, universal: arm64 + x86_64, stripped)"
"$ROOT/scripts/apply-engine-patches.sh"
mkdir -p build
(
  cd _sources/CLIProxyAPI
  # Both slices: the app binary itself is universal, and the embedded gateway
  # must be too — an arm64-only sidecar cannot start on Intel Macs.
  for ARCH in arm64 amd64; do
    CGO_ENABLED=0 GOOS=darwin GOARCH="$ARCH" go build -trimpath -ldflags "-s -w" \
      -o "$ROOT/build/cliproxyapi-$ARCH" ./cmd/server
  done
  lipo -create -output "$ROOT/build/cliproxyapi" \
    "$ROOT/build/cliproxyapi-arm64" "$ROOT/build/cliproxyapi-amd64"
  rm -f "$ROOT/build/cliproxyapi-arm64" "$ROOT/build/cliproxyapi-amd64"
)

echo "==> 1b/6 llama.cpp runtime (pinned, universal: arm64 + x86_64)"
# Never trust an existing folder: an arm64-only runtime left by an older build
# produces a bundle that cannot start on Intel Macs. The script checks the lipo
# slices, the dependency closure and the signatures, rebuilds in a staging
# folder when the runtime is stale, and swaps it in only after it passed.
"$ROOT/scripts/fetch-runtime.sh"
RUNTIME_ARCHS="$(lipo -archs "$ROOT/app/Resources/runtime/llama-server")"
for ARCH in arm64 x86_64; do
  case " $RUNTIME_ARCHS " in
    *" $ARCH "*) ;;
    *)
      echo "bundled llama-server has no $ARCH slice ($RUNTIME_ARCHS)" >&2
      exit 1
      ;;
  esac
done
# llama-server prints its build banner on stderr.
RUNTIME_VERSION="$("$ROOT/app/Resources/runtime/llama-server" --version 2>&1 | head -1 || true)"
[ -n "${RUNTIME_VERSION:-}" ] || RUNTIME_VERSION="unknown"
echo "    $RUNTIME_VERSION ($RUNTIME_ARCHS)"

echo "==> 2/6 app icon"
ICON_SRC=scripts/assets/source-appicon.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p app/Resources
iconutil -c icns "$ICONSET" -o app/Resources/AppIcon.icns

echo "==> 3/6 xcode project"
(cd app && xcodegen generate)

echo "==> 4/6 release build"
xcodebuild -project app/MelonTools.xcodeproj -scheme MelonTools -configuration Release \
  -derivedDataPath "$HOME/Library/Developer/MelonTools" build | tail -3

APP="$HOME/Library/Developer/MelonTools/Build/Products/Release/MelonTools.app"

echo "==> 5/6 ad-hoc codesign"
xattr -cr "$APP"
# Sign the embedded engine first, then the bundle. `--deep` is deprecated and
# can hide unsigned nested code; explicit signing makes the failure visible.
ENGINE="$APP/Contents/Resources/bin/cliproxyapi"
if [ -f "$ENGINE" ]; then
  codesign --force --options runtime --timestamp=none --sign - "$ENGINE"
fi
ENTITLEMENTS="$ROOT/app/MelonTools/MelonTools.entitlements"
if [ -f "$ENTITLEMENTS" ]; then
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" --sign - "$APP"
else
  codesign --force --options runtime --timestamp=none --sign - "$APP"
fi
codesign --verify --strict "$APP" && echo "signature ok"

echo "==> 6/6 dmg"
STAGE="$HOME/Library/Developer/MelonTools/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Melon Tools.app"
xattr -cr "$STAGE/Melon Tools.app"
codesign --verify --strict "$STAGE/Melon Tools.app" && echo "staged signature ok"
DMG="build/MelonTools-${VERSION}.dmg"
rm -f "$DMG"
# Try create-dmg (pretty Finder layout + volume icon). It needs Finder automation
# permission; in headless/agent contexts that times out, so fall back to hdiutil.
if command -v create-dmg >/dev/null 2>&1; then
  if create-dmg \
    --volname "Melon Tools" \
    --volicon app/Resources/AppIcon.icns \
    --window-size 640 400 \
    --icon-size 120 \
    --icon "Melon Tools.app" 160 190 \
    --app-drop-link 480 190 \
    --hide-extension "Melon Tools.app" \
    "$DMG" "$STAGE"; then
    :
  else
    rm -f "$DMG"
  fi
fi
# create-dmg needs Finder automation and can leave its interstitial RW image
# mounted when it fails — detach leftovers so no ghost app remains visible.
for VOL in /Volumes/dmg.*; do
  [ -d "$VOL" ] && hdiutil detach "$VOL" >/dev/null 2>&1 || true
done
if [ ! -f "$DMG" ]; then
  echo "create-dmg unavailable/failed — building plain compressed image with a volume icon"
  ln -sf /Applications "$STAGE/Applications"
  RW="build/MelonTools-rw.dmg"
  rm -f "$RW"
  hdiutil create -volname "Melon Tools" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
  MOUNT=$(hdiutil attach -nobrowse -readwrite "$RW" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
  if [ -n "${MOUNT:-}" ]; then
    cp app/Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
    if command -v SetFile >/dev/null 2>&1; then
      SetFile -c icnC -a C "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
      SetFile -a C "$MOUNT" 2>/dev/null || true
    fi
    sync
    hdiutil detach "$MOUNT" >/dev/null
  fi
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
  rm -f "$RW"
fi
rm -f build/rw.*.dmg 2>/dev/null || true
echo "DMG ready: $ROOT/$DMG"

# Every DMG build mounts a temporary volume; LaunchServices keeps each of them
# registered after the detach, and the stale entries keep answering icon lookups
# for `dev.melontools.app`, so Finder and the Dock show an older artwork. Drop
# the temporary copies we just created (installed copies are left alone).
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -dump 2>/dev/null \
  | grep -E "^ *path: .*/Melon( Tools)?\.app" \
  | sed -E 's/^ *path: *//; s/ \(0x[0-9a-f]+\)$//' \
  | while IFS= read -r stale; do
      case "$stale" in
        /Volumes/dmg.*|*/Library/Developer/*|*/dmg-stage/*) "$LSREG" -u "$stale" >/dev/null 2>&1 || true ;;
      esac
    done || true

cp "$DMG" "$ROOT/"
echo "copied to $ROOT/"
