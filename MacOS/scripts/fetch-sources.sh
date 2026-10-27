#!/bin/bash
# Fetch the pinned third-party source required to build the gateway engine.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p _sources

if [ ! -d _sources/CLIProxyAPI ]; then
  git clone https://github.com/router-for-me/CLIProxyAPI.git _sources/CLIProxyAPI
fi
git -C _sources/CLIProxyAPI fetch --all --tags --quiet || true
# v8.0.44: Go 1.26.10, x/net 0.60.0, x/crypto 0.57.0, go-git v6 alpha.5,
# x/text 0.42.0. It still pins klauspost/compress 1.17.4, so bump that one
# dependency to the fixed 1.18.7 before building.
git -C _sources/CLIProxyAPI checkout --quiet --force 1f917e77c4562623aa49e9804d999524151a2f96
(
  cd _sources/CLIProxyAPI
  GOTOOLCHAIN=go1.26.10 go get github.com/klauspost/compress@v1.18.7
  GOTOOLCHAIN=go1.26.10 go mod tidy
)

echo "gateway source ready:"
git -C _sources/CLIProxyAPI rev-parse --short HEAD
grep -E 'golang.org/x/(net|crypto|text)|go-git/go-git|klauspost/compress' _sources/CLIProxyAPI/go.mod
