#!/usr/bin/env bash
# Fetch ripgrep release tarballs (one per macOS arch), verify their SHA256
# against scripts/ripgrep-checksums.txt, lipo into a universal binary, and
# install at Resources/bin/rg so the cmux app bundle ships a working `rg` for
# users who don't have ripgrep installed system-wide.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

RIPGREP_VERSION="${CMUX_RIPGREP_VERSION:-15.1.0}"
CHECKSUMS_FILE="${CMUX_RIPGREP_CHECKSUMS_FILE:-$SCRIPT_DIR/ripgrep-checksums.txt}"
CACHE_ROOT="${CMUX_RIPGREP_CACHE_DIR:-$HOME/.cache/cmux/ripgrep}"
CACHE_DIR="$CACHE_ROOT/$RIPGREP_VERSION"
DEST_DIR="$PROJECT_DIR/Resources/bin"
DEST_PATH="$DEST_DIR/rg"
STAMP_PATH="$DEST_PATH.version"

ARCHIVE_AARCH64="ripgrep-${RIPGREP_VERSION}-aarch64-apple-darwin.tar.gz"
ARCHIVE_X86_64="ripgrep-${RIPGREP_VERSION}-x86_64-apple-darwin.tar.gz"
RELEASE_BASE="https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}"

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

lookup_pinned_sha() {
  local archive="$1"
  awk -v want="$archive" '
    $0 ~ /^[[:space:]]*#/ { next }
    NF >= 2 && $2 == want { print $1; found = 1; exit }
    END { if (!found) exit 1 }
  ' "$CHECKSUMS_FILE"
}

fetch_and_extract_arch() {
  local archive="$1"
  local out_dir="$2"
  local expected_sha
  if ! expected_sha="$(lookup_pinned_sha "$archive" 2>/dev/null)"; then
    echo "error: no pinned SHA256 for $archive in $CHECKSUMS_FILE" >&2
    return 1
  fi

  mkdir -p "$out_dir"
  local archive_path="$out_dir/$archive"

  local actual_sha=""
  if [[ -f "$archive_path" ]]; then
    actual_sha="$(hash_file "$archive_path")"
  fi
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "==> Downloading $archive..." >&2
    if ! "$SCRIPT_DIR/download-with-retry.sh" "$RELEASE_BASE/$archive" "$archive_path" >&2; then
      echo "error: failed to download $archive" >&2
      return 1
    fi
    actual_sha="$(hash_file "$archive_path")"
  fi
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "error: SHA256 mismatch for $archive" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   $actual_sha" >&2
    rm -f "$archive_path"
    return 1
  fi

  local extract_dir="$out_dir/${archive%.tar.gz}"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  tar --no-same-owner -xzf "$archive_path" -C "$extract_dir" >&2

  local rg_bin
  rg_bin="$(find "$extract_dir" -type f -name rg -perm -u+x 2>/dev/null | head -n 1)"
  if [[ -z "$rg_bin" || ! -x "$rg_bin" ]]; then
    echo "error: extracted $archive but no rg binary inside" >&2
    return 1
  fi
  printf '%s\n' "$rg_bin"
}

if [[ ! -f "$CHECKSUMS_FILE" ]]; then
  echo "error: missing $CHECKSUMS_FILE" >&2
  exit 1
fi

# Fast path: already installed at the pinned version.
if [[ -x "$DEST_PATH" && -f "$STAMP_PATH" ]] && [[ "$(cat "$STAMP_PATH")" == "$RIPGREP_VERSION" ]]; then
  echo "==> ripgrep $RIPGREP_VERSION already installed at $DEST_PATH"
  exit 0
fi

mkdir -p "$CACHE_DIR" "$DEST_DIR"

echo "==> Ensuring ripgrep $RIPGREP_VERSION universal binary at $DEST_PATH"

# Download both archs in parallel and capture each function's stdout (the rg
# path) into a tempfile so we don't serialize ~2-4s of network on first build.
AARCH64_OUT="$CACHE_DIR/.aarch64.path"
X86_64_OUT="$CACHE_DIR/.x86_64.path"
rm -f "$AARCH64_OUT" "$X86_64_OUT"
fetch_and_extract_arch "$ARCHIVE_AARCH64" "$CACHE_DIR" > "$AARCH64_OUT" &
PID_AARCH64=$!
fetch_and_extract_arch "$ARCHIVE_X86_64" "$CACHE_DIR" > "$X86_64_OUT" &
PID_X86_64=$!
FAILED=0
wait "$PID_AARCH64" || FAILED=1
wait "$PID_X86_64" || FAILED=1
if [[ "$FAILED" -ne 0 ]]; then
  echo "error: ripgrep arch fetch failed" >&2
  exit 1
fi
RG_AARCH64="$(cat "$AARCH64_OUT")"
RG_X86_64="$(cat "$X86_64_OUT")"

if ! command -v lipo >/dev/null 2>&1; then
  echo "error: lipo is required to build a universal rg binary" >&2
  exit 1
fi

TMP_OUT="$DEST_PATH.tmp"
rm -f "$TMP_OUT"
lipo -create -output "$TMP_OUT" "$RG_AARCH64" "$RG_X86_64"
chmod +x "$TMP_OUT"
mv "$TMP_OUT" "$DEST_PATH"
printf '%s\n' "$RIPGREP_VERSION" > "$STAMP_PATH"

echo "==> Installed ripgrep $RIPGREP_VERSION (universal) at $DEST_PATH"
