#!/usr/bin/env bash
# fetch-ffmpeg.sh — Download pinned FFmpeg/ffprobe into WaxOnWaxOff/ for bundling.
#
# Binaries are stored as GitHub release assets (not in git) to keep the repo lean.
# Safe to run repeatedly; skips the network when local files match the manifest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$PROJECT_DIR/Vendor/ffmpeg-manifest.env"
DEST_DIR="$PROJECT_DIR/WaxOnWaxOff"

if [[ ! -f "$MANIFEST" ]]; then
    echo "Missing manifest: $MANIFEST" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$MANIFEST"

FFMPEG_PATH="$DEST_DIR/ffmpeg"
FFPROBE_PATH="$DEST_DIR/ffprobe"

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

verify_pair() {
    [[ -f "$FFMPEG_PATH" && -f "$FFPROBE_PATH" ]] || return 1
    [[ "$(sha256_file "$FFMPEG_PATH")" == "$FFMPEG_SHA256" ]] || return 1
    [[ "$(sha256_file "$FFPROBE_PATH")" == "$FFPROBE_SHA256" ]] || return 1
    return 0
}

if verify_pair; then
    chmod 755 "$FFMPEG_PATH" "$FFPROBE_PATH" 2>/dev/null || true
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download FFmpeg binaries." >&2
    exit 1
fi

BASE_URL="${FFMPEG_DEPS_BASE_URL:-https://github.com/${FFMPEG_DEPS_REPO}/releases/download/${FFMPEG_DEPS_TAG}}"
mkdir -p "$DEST_DIR"

download_one() {
    local name="$1"
    local expected="$2"
    local dest="$3"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/waxon-${name}.XXXXXX")"

    if ! curl -fL --retry 3 --retry-delay 2 -o "$tmp" "${BASE_URL}/${name}"; then
        rm -f "$tmp"
        echo "Failed to download ${name} from ${BASE_URL}/${name}" >&2
        echo "If this is a fresh clone, ensure release ${FFMPEG_DEPS_TAG} exists on GitHub." >&2
        exit 1
    fi

    local got
    got="$(sha256_file "$tmp")"
    if [[ "$got" != "$expected" ]]; then
        rm -f "$tmp"
        echo "Checksum mismatch for ${name}: expected ${expected}, got ${got}" >&2
        exit 1
    fi

    mv "$tmp" "$dest"
    chmod 755 "$dest"
}

download_one ffmpeg "$FFMPEG_SHA256" "$FFMPEG_PATH"
download_one ffprobe "$FFPROBE_SHA256" "$FFPROBE_PATH"

echo "Fetched FFmpeg ${FFMPEG_VERSION} (${FFMPEG_ARCH})"
