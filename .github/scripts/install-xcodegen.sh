#!/bin/bash
# Install a pinned XcodeGen release and expose it on GITHUB_PATH.
# Homebrew's `brew install xcodegen` floats with the latest formula, so CI
# would silently change the project generator between runs.
set -euo pipefail
VERSION="2.46.0"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip"
DEST="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xcodegen-${VERSION}"
ARCHIVE="${DEST}.zip"

mkdir -p "$DEST"
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "$URL" -o "$ARCHIVE"
echo "${SHA256}  ${ARCHIVE}" | shasum -a 256 -c -
unzip -q -o "$ARCHIVE" -d "$DEST"
BIN="$DEST/xcodegen/bin"
chmod +x "$BIN/xcodegen"
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$BIN" >> "$GITHUB_PATH"
else
  echo "XcodeGen $VERSION at $BIN/xcodegen"
fi
"$BIN/xcodegen" --version
