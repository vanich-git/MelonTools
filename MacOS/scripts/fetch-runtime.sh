#!/bin/bash
# Fetches the pinned llama.cpp runtime into the app bundle.
#
# The specification (§4.4, §5.3) requires a pinned, checksummed runtime shipped
# with the application instead of a Homebrew dependency.
#
# Upstream publishes one macOS archive per architecture, so "universal" here
# means: verify both archives against pinned digests, then merge them with lipo
# into a single `llama-server` plus one set of dylibs. The local machine is
# never asked what it is — `uname -m` says nothing about what the bundle must
# contain, and running on arm64 does not make an arm64-only runtime universal.
#
# Every mutation happens in a staging directory. The live runtime is replaced
# only after the staged copy passed the arch/dependency/signature checks, so a
# failed download or merge leaves the previous working runtime untouched.
#
# Usage:
#   fetch-runtime.sh                    ensure the bundled runtime is universal
#   fetch-runtime.sh --check            verify it only; exit 1 when stale
#   fetch-runtime.sh --refresh-manifest rewrite runtime.sha256/runtime.json
#                                       after the nested binaries were re-signed
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned upstream build. Bump deliberately, never track "latest".
LLAMA_TAG="${LLAMA_TAG:-b12099}"
RESOURCES="$ROOT/app/Resources"
# Overridable so the test script can exercise the real flow against a sandbox.
DEST="${RUNTIME_DEST:-$RESOURCES/runtime}"
CACHE="${RUNTIME_CACHE:-$ROOT/build/runtime-cache}"
DEST="${DEST%/}"
CACHE="${CACHE%/}"
DEST_PARENT="${DEST%/*}"
CHECK_ONLY=0
REFRESH_MANIFEST=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'TXT'
usage: fetch-runtime.sh [--check | --refresh-manifest]

  (no argument)       ensure the bundled runtime is universal, rebuilding it
                      when the installed folder is missing, arm64-only or
                      unsigned
  --check             verify the bundled runtime only; exit 1 when it is stale
  --refresh-manifest  recompute runtime.sha256/runtime.json after the nested
                      Mach-O files were re-signed; does not download or sign
TXT
}

sha256_file() { shasum -a 256 "$1" | cut -d' ' -f1; }

macho_archs() { lipo -archs "$1" 2>/dev/null || true; }

has_arch() {
  local list
  list=" $(macho_archs "$1") "
  case "$list" in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Upstream SHA-256 of each release asset, taken from the GitHub release digest
# for the pinned tag. Hardcoded on purpose: a tag can be repointed upstream, a
# digest cannot. Add a row when LLAMA_TAG is bumped.
pinned_sha256() {
  case "$LLAMA_TAG/$1" in
    b12099/arm64) echo "e0b7de85181945f3fa12ca2a23e69d1eb8d659fe6f6eabcaf2c4a589733bfaca" ;;
    b12099/x64)   echo "39ebbcf4747886911fa1f89c0c4ee7f802746a9980ffa83e85a5f7c0e7b9cfe6" ;;
    *) return 1 ;;
  esac
}

# The app can supply an already-downloaded archive and its digest. The pinned
# table stays as the fallback for command-line builds.
expected_sha256() {
  local arch="$1" override=""
  if [ "$arch" = "arm64" ]; then
    override="${RUNTIME_SHA_ARM64:-}"
  else
    override="${RUNTIME_SHA_X64:-}"
  fi
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  pinned_sha256 "$arch"
}

# Deletion is restricted to paths we create under the bundle or the cache.
# Guards against `rm -rf "$UNSET/"` style bugs and symlinked runtime folders.
safe_rm_rf() {
  local target="$1" root
  [ -n "$target" ] || die "refusing to delete an empty path"
  case "$target" in
    /*) ;;
    *) die "refusing to delete a relative path: $target" ;;
  esac
  case "$target" in
    /|"$HOME"|"$ROOT") die "refusing to delete $target" ;;
  esac
  if [ -L "$target" ]; then
    die "refusing to delete symlink $target"
  fi
  for root in "$DEST_PARENT" "$CACHE"; do
    case "$target" in
      "$root"/?*)
        rm -rf -- "$target"
        return 0
        ;;
    esac
  done
  die "refusing to delete $target: outside the managed directories"
}

# Reports everything that keeps the folder from being a universal runtime.
# One problem per line; empty output means the folder is good.
rpath_problems() {
  local file="$1" arch="$2" dir="$3" out="" dep name
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      @rpath/*)
        name="${dep#@rpath/}"
        if [ ! -f "$dir/$name" ]; then
          out="${out}${file##*/}[${arch}]: missing ${name}"$'\n'
        elif ! has_arch "$dir/$name" "$arch"; then
          out="${out}${file##*/}[${arch}]: ${name} has no ${arch} slice"$'\n'
        fi
        ;;
      /usr/lib/*|/System/*) ;;
      *) out="${out}${file##*/}[${arch}]: non-system dependency ${dep}"$'\n' ;;
    esac
  done < <(otool -arch "$arch" -L "$file" 2>/dev/null \
             | tail -n +2 | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
  printf '%s' "$out"
}

runtime_problems() {
  local dir="$1" out="" f n archs a deps platform build expected

  if [ ! -f "$dir/llama-server" ]; then
    printf 'llama-server is missing\n'
    return 0
  fi
  if [ ! -x "$dir/llama-server" ]; then
    out="${out}llama-server is not executable"$'\n'
  fi

  archs="$(macho_archs "$dir/llama-server")"
  for a in arm64 x86_64; do
    case " $archs " in
      *" $a "*) ;;
      *) out="${out}llama-server has no ${a} slice (archs: ${archs:-none})"$'\n' ;;
    esac
  done

  if [ ! -f "$dir/runtime.json" ]; then
    out="${out}runtime.json is missing"$'\n'
  else
    platform="$(sed -n 's/.*"platform":[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/runtime.json")"
    [ "$platform" = "macos-universal" ] \
      || out="${out}runtime.json: platform is '${platform}', expected 'macos-universal'"$'\n'
    build="$(sed -n 's/.*"build":[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/runtime.json")"
    [ "$build" = "$LLAMA_TAG" ] \
      || out="${out}runtime.json: build is '${build}', expected '${LLAMA_TAG}'"$'\n'
    expected="$(sed -n 's/.*"sha256":[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/runtime.json")"
    [ "$expected" = "$(sha256_file "$dir/llama-server")" ] \
      || out="${out}runtime.json: sha256 does not match llama-server (digest must be taken after signing)"$'\n'
  fi

  # Every Mach-O in the folder is checked against the slices it claims to have.
  # A dylib may be arm64-only (upstream ships no Metal backend for Intel), but
  # only as long as no x86_64 slice links it — the closure check decides.
  for f in "$dir/llama-server" "$dir"/*.dylib; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    case "$n" in ._*) continue ;; esac
    archs="$(macho_archs "$f")"
    if [ -z "$archs" ]; then
      out="${out}${n}: not a Mach-O binary"$'\n'
      continue
    fi
    for a in $archs; do
      case "$a" in
        arm64|x86_64) ;;
        *) out="${out}${n}: unexpected architecture ${a}"$'\n' ;;
      esac
      deps="$(rpath_problems "$f" "$a" "$dir")"
      out="${out}${deps}"
    done
  done

  if command -v codesign >/dev/null 2>&1 \
     && ! codesign --verify --strict "$dir/llama-server" >/dev/null 2>&1; then
    out="${out}llama-server signature is missing or invalid"$'\n'
  fi

  printf '%s' "$out"
}

download_archive() {
  local arch="$1" expected="$2"
  local asset="llama-${LLAMA_TAG}-bin-macos-${arch}.tar.gz"
  local url="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/${asset}"
  local out="$CACHE/$asset" part="$CACHE/$asset.part" actual

  if [ -f "$out" ] && [ "$(sha256_file "$out")" = "$expected" ]; then
    echo "    cached   $asset"
    return 0
  fi

  echo "==> downloading $asset"
  rm -f -- "$part"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$part" "$url" \
    || die "download failed: $url"
  actual="$(sha256_file "$part")"
  if [ "$actual" != "$expected" ]; then
    rm -f -- "$part"
    die "$asset: SHA-256 mismatch (expected $expected, got $actual)"
  fi
  mv -- "$part" "$out"
  echo "    verified $asset"
}

# Stages an app-downloaded archive into the cache after verifying its digest,
# so the merge path is identical to a command-line build.
stage_local_archive() {
  local arch="$1" src="$2" expected="$3"
  local asset="llama-${LLAMA_TAG}-bin-macos-${arch}.tar.gz"
  local out="$CACHE/$asset" actual
  if [ -f "$out" ] && [ "$(sha256_file "$out")" = "$expected" ]; then
    echo "    cached   $asset"
    return 0
  fi
  [ -f "$src" ] || die "local archive not found: $src"
  actual="$(sha256_file "$src")"
  [ "$actual" = "$expected" ] || die "$asset: local SHA-256 mismatch"
  cp -- "$src" "$out" || die "cannot stage $asset"
  echo "    staged   $asset"
}

extract_archive() {
  local arch="$1"
  local asset="llama-${LLAMA_TAG}-bin-macos-${arch}.tar.gz"
  local unpack="$CACHE/$LLAMA_TAG/$arch"
  safe_rm_rf "$unpack"
  mkdir -p "$unpack"
  tar -xzf "$CACHE/$asset" -C "$unpack" || die "cannot extract $asset"
}

# Directory inside an extracted archive that holds llama-server and the dylibs.
src_dir() {
  local arch="$1" found
  found="$(find "$CACHE/$LLAMA_TAG/$arch" -type f -name llama-server -not -name '._*' -print -quit)"
  [ -n "$found" ] || return 1
  printf '%s\n' "${found%/*}"
}

compose() {
  local dir="$1" arm_src="$2" x64_src="$3" f n

  lipo -create -output "$dir/llama-server" \
    "$arm_src/llama-server" "$x64_src/llama-server" \
    || die "lipo failed for llama-server"
  chmod 755 "$dir/llama-server"

  # Union of both archives: shared dylibs become universal, arch-exclusive ones
  # are copied as-is and vetted by the dependency closure check afterwards.
  # Today that is only libggml-metal*: upstream ships no Metal backend for
  # Intel, and the x86_64 llama-server does not link it (verified below).
  for f in "$arm_src"/*.dylib; do
    n="${f##*/}"
    case "$n" in ._*) continue ;; esac
    if [ -f "$x64_src/$n" ]; then
      lipo -create -output "$dir/$n" "$x64_src/$n" "$f" || die "lipo failed for $n"
    else
      cp -p "$f" "$dir/$n"
    fi
  done
  for f in "$x64_src"/*.dylib; do
    n="${f##*/}"
    case "$n" in ._*) continue ;; esac
    if [ -f "$arm_src/$n" ]; then continue; fi
    cp -p "$f" "$dir/$n"
  done

  # Upstream already names dylibs @rpath/<file> and gives llama-server a
  # @loader_path rpath; only patch when that ever stops being true.
  for f in "$dir"/*.dylib; do
    n="${f##*/}"
    case "$n" in ._*) continue ;; esac
    if [ "$(otool -D "$f" | tail -n +2 | head -1)" != "@rpath/$n" ]; then
      install_name_tool -id "@rpath/$n" "$f" \
        || die "install_name_tool failed for $n"
    fi
  done
  if ! otool -l "$dir/llama-server" | grep -qE '@(loader|executable)_path'; then
    install_name_tool -add_rpath "@executable_path" "$dir/llama-server" \
      || die "install_name_tool failed for llama-server"
  fi
}

# Ad-hoc signature is what makes the arm64 slices loadable at all, and it must
# happen after lipo/install_name_tool: both invalidate signatures.
sign_runtime() {
  local dir="$1" f n
  for f in "$dir/llama-server" "$dir"/*.dylib; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    case "$n" in ._*) continue ;; esac
    codesign --force --sign - --timestamp=none "$f" >/dev/null 2>&1 \
      || die "codesign failed for $n"
    codesign --verify --strict "$f" >/dev/null 2>&1 \
      || die "signature verification failed for $n"
  done
}

write_manifest() {
  local dir="$1" version digest size

  # The app never executes a freshly downloaded engine: it passes
  # RUNTIME_SKIP_VERSION=1 and records the release tag instead.
  if [ "${RUNTIME_SKIP_VERSION:-0}" != "1" ]; then
    version="$("$dir/llama-server" --version 2>&1 \
                 | sed -n 's/^version: \([^ ]*\).*/\1/p' | head -1 || true)"
  fi
  [ -n "${version:-}" ] || version="$LLAMA_TAG"
  printf '%s\n' "$version" > "$dir/runtime.version"
  printf '%s\n' "$LLAMA_TAG" > "$dir/runtime.tag"

  # Digest of the signed binary: RuntimeStore compares this value against the
  # file it is about to execute, so it has to be taken last.
  digest="$(sha256_file "$dir/llama-server")"
  printf '%s  llama-server\n' "$digest" > "$dir/runtime.sha256"

  size="$(du -sk "$dir" | cut -f1)"
  cat > "$dir/runtime.json" <<JSON
{
  "id": "metal-macos-universal-${LLAMA_TAG}",
  "backend": "metal",
  "platform": "macos-universal",
  "build": "${LLAMA_TAG}",
  "version": "${version}",
  "sha256": "${digest}",
  "cpu_extensions": [],
  "size_bytes": $((size * 1024)),
  "bundled": true
}
JSON
}

# Re-signing a nested binary changes its bytes, so the digest recorded at build
# time no longer matches. The release signing step calls this after code
# signing and before the outer app bundle is sealed, so the manifest inside the
# signature describes the exact binary that ships.
refresh_manifest() {
  local dir="$1" version build platform digest size json
  local new_json

  [ -f "$dir/llama-server" ] || die "cannot refresh: llama-server is missing"
  [ -f "$dir/runtime.json" ] || die "cannot refresh: runtime.json is missing"

  json="$(cat "$dir/runtime.json")"
  platform="$(printf '%s\n' "$json" \
    | sed -n 's/.*"platform":[[:space:]]*"\([^"]*\)".*/\1/p')"
  build="$(printf '%s\n' "$json" \
    | sed -n 's/.*"build":[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ "$platform" = "macos-universal" ] \
    || die "cannot refresh: runtime.json platform is '${platform}'"
  [ "$build" = "$LLAMA_TAG" ] \
    || die "cannot refresh: runtime.json build is '${build}', expected '$LLAMA_TAG'"

  version="$(cat "$dir/runtime.version" 2>/dev/null || true)"
  [ -n "$version" ] || version="$LLAMA_TAG"

  digest="$(sha256_file "$dir/llama-server")"
  size="$(du -sk "$dir" | cut -f1)"
  new_json="$(printf '%s\n' "$json" \
    | sed -E "s/(\"sha256\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1${digest}\2/" \
    | sed -E "s/(\"size_bytes\"[[:space:]]*:[[:space:]]*)[0-9]+/\1$((size * 1024))/")"
  if ! printf '%s\n' "$new_json" | grep -q "\"sha256\": \"$digest\""; then
    die "cannot refresh: runtime.json has no sha256 field"
  fi
  if ! printf '%s\n' "$new_json" | grep -q "\"size_bytes\": $((size * 1024))"; then
    die "cannot refresh: runtime.json has no size_bytes field"
  fi
  printf '%s\n' "$new_json" > "$dir/runtime.json"
  printf '%s  llama-server\n' "$digest" > "$dir/runtime.sha256"
  printf '%s\n' "$version" > "$dir/runtime.version"
}

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --refresh-manifest) REFRESH_MANIFEST=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
if [ "$CHECK_ONLY" -eq 1 ] && [ "$REFRESH_MANIFEST" -eq 1 ]; then
  die "--check and --refresh-manifest are mutually exclusive"
fi

for tool in curl shasum tar lipo otool install_name_tool codesign; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

case "$DEST" in
  /*) ;;
  *) die "runtime destination must be an absolute path: $DEST" ;;
esac
case "$CACHE" in
  /*) ;;
  *) die "runtime cache must be an absolute path: $CACHE" ;;
esac
[ "${DEST##*/}" = "runtime" ] \
  || die "refusing to manage $DEST: expected a directory named 'runtime'"
[ -n "$DEST_PARENT" ] \
  || die "refusing to manage $DEST: it must live in a directory, not at /"
if [ -L "$DEST" ]; then
  die "refusing to replace $DEST: it is a symlink"
fi

if [ "$REFRESH_MANIFEST" -eq 1 ]; then
  refresh_manifest "$DEST"
  problems="$(runtime_problems "$DEST")"
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | sed 's/^/    /' >&2
    die "refreshed runtime failed verification"
  fi
  echo "==> runtime manifest refreshed after signing"
  echo "    archs:  $(macho_archs "$DEST/llama-server")"
  echo "    sha256: $(cut -d' ' -f1 "$DEST/runtime.sha256")"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  problems="$(runtime_problems "$DEST")"
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | sed 's/^/    /' >&2
    exit 1
  fi
  echo "==> runtime: universal (arm64 + x86_64), up to date"
  exit 0
fi

problems="$(runtime_problems "$DEST")"
if [ -z "$problems" ]; then
  echo "==> llama.cpp runtime: $LLAMA_TAG, already universal"
  exit 0
fi
echo "==> llama.cpp runtime: $LLAMA_TAG, rebuilding"
printf '%s\n' "$problems" | sed 's/^/    stale: /'

mkdir -p "$CACHE" "$DEST_PARENT"
for arch in arm64 x64; do
  expected="$(expected_sha256 "$arch")" \
    || die "no SHA-256 for LLAMA_TAG=$LLAMA_TAG ($arch); pass RUNTIME_SHA_ARM64/RUNTIME_SHA_X64"
  local_src=""
  case "$arch" in
    arm64) local_src="${RUNTIME_LOCAL_ARM64:-}" ;;
    x64) local_src="${RUNTIME_LOCAL_X64:-}" ;;
  esac
  if [ -n "$local_src" ]; then
    stage_local_archive "$arch" "$local_src" "$expected"
  else
    download_archive "$arch" "$expected"
  fi
  extract_archive "$arch"
done

ARM_SRC="$(src_dir arm64)" || die "llama-server not found in the arm64 archive"
X64_SRC="$(src_dir x64)" || die "llama-server not found in the x64 archive"

NEW="$DEST.new.$$"
OLD="$DEST.old.$$"
COMMITTED=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "${NEW:-}" ] && [ -d "$NEW" ]; then
    safe_rm_rf "$NEW" 2>/dev/null || true
  fi
  if [ "$COMMITTED" -ne 1 ] && [ -n "${OLD:-}" ] && [ -d "$OLD" ] && [ ! -e "$DEST" ]; then
    mv -- "$OLD" "$DEST" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT

safe_rm_rf "$NEW"
mkdir -p "$NEW"
compose "$NEW" "$ARM_SRC" "$X64_SRC"
sign_runtime "$NEW"
write_manifest "$NEW"

problems="$(runtime_problems "$NEW")"
if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed 's/^/    /' >&2
  die "staged runtime failed verification; the installed runtime is untouched"
fi

# Atomic swap: the old folder stays until the new one is in place.
if [ -e "$OLD" ]; then safe_rm_rf "$OLD"; fi
if [ -d "$DEST" ]; then
  mv -- "$DEST" "$OLD"
fi
mv -- "$NEW" "$DEST"
COMMITTED=1
safe_rm_rf "$OLD"

echo "==> archs:  $(macho_archs "$DEST/llama-server")"
echo "==> version: $(cat "$DEST/runtime.version")"
echo "==> sha256: $(cut -d' ' -f1 "$DEST/runtime.sha256")"
echo "==> size:   $(du -sh "$DEST" | cut -f1)"
