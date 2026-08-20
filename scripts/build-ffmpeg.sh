#!/usr/bin/env bash
# build-ffmpeg.sh — Build the pinned audio-only static ffmpeg/ffprobe for bundling.
#
# Produces LGPL-2.1-or-later binaries: FFmpeg 8.0 with libmp3lame (LAME 3.100),
# NO --enable-gpl / --enable-nonfree, no video/image external libraries. This is
# the Corresponding Source recipe — provenance is ours, not a third-party build.
#
# Written to bash 3.2 (the /bin/bash macOS ships, frozen because Apple won't ship
# GPLv3). No mapfile/readarray, no `declare -A`, no ${var,,}, no &>>.
#
# Reproducible: two runs on the same toolchain produce byte-identical binaries,
# so anyone can rebuild and check the SHA-256 against the pin in
# Vendor/ffmpeg-manifest.env. Three things make that true — the fixed working
# directory below (configure bakes --prefix into the binary), -ffp-contract=off,
# and -Wl,-no_uuid. Without the last one two runs differ in exactly 48 bytes:
# the 16-byte linker-generated LC_UUID, plus the 32-byte ad-hoc code-signature
# hash in __LINKEDIT that covers it. Dropping LC_UUID costs only crash
# symbolication of the bundled binary, which we never do — it runs as a separate
# process and release.sh re-signs it anyway.
# To re-verify: run twice into different output dirs and compare SHA-256.
#
# Usage: scripts/build-ffmpeg.sh [output-dir]   (default: ./build/ffmpeg-audio)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PBXPROJ="$PROJECT_DIR/WaxOnWaxOff.xcodeproj/project.pbxproj"
OUT_DIR="${1:-$PROJECT_DIR/build/ffmpeg-audio}"

# --- Pinned sources (SHA-256 verified; see Vendor/README.md) --------------------
FFMPEG_VERSION="8.0"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA="b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e"
LAME_VERSION="3.100"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"
LAME_SHA="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"

# --- Deployment target: read from the project, assert all configs agree ---------
# grep -m1 would silently pick one of Debug/Release × project/target; instead
# collect the distinct values and fail if they disagree.
dt_values="$(grep -oE 'MACOSX_DEPLOYMENT_TARGET = [0-9.]+' "$PBXPROJ" | grep -oE '[0-9]+(\.[0-9]+)?' | sort -u)"
dt_count="$(printf '%s\n' "$dt_values" | grep -c .)"
if [ "$dt_count" -ne 1 ]; then
    printf 'MACOSX_DEPLOYMENT_TARGET disagrees across configs: %s\n' "$dt_values" >&2
    exit 1
fi
DEPTARGET="$dt_values"

# FIXED path, deliberately not mktemp. configure bakes --prefix into the binary's
# configuration string, so a randomized working directory makes every run produce
# a different binary — and a Corresponding Source recipe that cannot reproduce its
# own artifact is not much of a recipe. A literal /tmp path (not $TMPDIR, which is
# per-user on macOS) keeps the embedded string identical across machines too.
# Cleared at start; concurrent runs of this script are not supported.
WORK="/tmp/waxonwaxoff-ffmpeg-build"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"

echo "▶ audio-only FFmpeg ${FFMPEG_VERSION} + LAME ${LAME_VERSION}, arm64, min macOS ${DEPTARGET}"

# dl <dest> <url> <sha256>: download and verify, fail-closed on mismatch.
dl() { curl -fL --retry 3 --retry-delay 2 -o "$1" "$2"; s="$(shasum -a 256 "$1" | awk '{print $1}')"; [ "$s" = "$3" ] || { echo "checksum mismatch $2: $s" >&2; exit 1; }; }

cd "$WORK"
dl lame.tar.gz    "$LAME_URL"   "$LAME_SHA"
dl ffmpeg.tar.xz  "$FFMPEG_URL" "$FFMPEG_SHA"

CFL="-mmacosx-version-min=${DEPTARGET} -arch arm64"

# --- LAME (static, encoder only) ------------------------------------------------
echo "▶ LAME ${LAME_VERSION}"
tar xzf lame.tar.gz
cd "lame-${LAME_VERSION}"
CFLAGS="$CFL" LDFLAGS="$CFL" ./configure \
    --prefix="$WORK/lame-install" --disable-shared --enable-static --disable-frontend >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
cd "$WORK"

# --- FFmpeg (static, audio-only, LGPL) ------------------------------------------
echo "▶ FFmpeg ${FFMPEG_VERSION}"
tar xf ffmpeg.tar.xz
cd "ffmpeg-${FFMPEG_VERSION}"
./configure \
    --prefix="$WORK/ffmpeg-install" \
    --cc=/usr/bin/clang --arch=arm64 \
    --extra-cflags="-mmacosx-version-min=${DEPTARGET} -fno-stack-check -ffp-contract=off -I$WORK/lame-install/include" \
    --extra-ldflags="-mmacosx-version-min=${DEPTARGET} -L$WORK/lame-install/lib -Wl,-no_uuid" \
    --enable-static --disable-shared --pkg-config-flags=--static \
    --enable-libmp3lame \
    --disable-autodetect \
    --enable-zlib \
    --disable-ffplay \
    --enable-neon --enable-runtime-cpudetect >/dev/null
# -fno-stack-check: macOS clang enables -fstack-check by default; it breaks
# FFmpeg's codegen. Carried unconditionally — an input-dependent codegen bug is
# not something a parity corpus can clear, so this is never dropped on a passing run.
#
# -ffp-contract=off: build reproducibility. Clang contracts a*b+c into FMA by
# default, and the contraction it chooses varies with compiler version. Inside a
# recursive IIR biquad (highpass, allpass) that difference accumulates through the
# feedback path, so the SAME source compiled by two clang versions produces
# measurably different audio. Disabling contraction makes the filter output depend
# on the source alone, not on which toolchain built it. Keep this flag on any
# FFmpeg version — it is not tied to a particular release or a one-off comparison.
#
# Evidence (2026-07, clang 13.1.6 vs 17.0.0): with contraction on, highpass nulled
# at -84.29 dBFS and allpass at -90.31 dBFS; with it off both null at -inf, and
# decoded-PCM MD5s match across the whole corpus. No throughput cost measured
# (0.53s vs 0.53s, 5x a 20s file).
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null

BIN="$WORK/ffmpeg-install/bin"

# --- Verification gates (fail-closed) -------------------------------------------
echo "▶ verifying"
# The binary must actually RUN before any grep-based check means anything: if it
# cannot execute (e.g. a missing dylib), cfg is empty and every "flag absent"
# assertion passes vacuously. Assert execution first.
"$BIN/ffmpeg" -hide_banner -version >/dev/null 2>&1 || { echo "FAIL: built ffmpeg does not execute" >&2; exit 1; }
cfg="$("$BIN/ffmpeg" -hide_banner -version | grep '^configuration:')"
[ -n "$cfg" ] || { echo "FAIL: no configuration string from built ffmpeg" >&2; exit 1; }
# No non-system dynamic dependencies. --disable-autodetect stops configure from
# silently linking whatever happens to be installed on the build machine (a
# Homebrew libxcb/X11 chain got linked this way and made the signed binary
# fail to load on any machine without that exact Homebrew build).
for b in ffmpeg ffprobe; do
    extern="$(otool -L "$BIN/$b" | tail -n +2 | grep -vE '/usr/lib/|/System/Library/' || true)"
    [ -z "$extern" ] || { echo "FAIL: $b has non-system dynamic deps:" >&2; echo "$extern" >&2; exit 1; }
done
for bad in enable-gpl enable-nonfree enable-version3; do
    printf '%s' "$cfg" | grep -q -- "--$bad" && { echo "FAIL: --$bad present" >&2; exit 1; }
done
printf '%s' "$cfg" | grep -q -- '--enable-libmp3lame' || { echo "FAIL: libmp3lame missing" >&2; exit 1; }
minos="$(otool -l "$BIN/ffmpeg" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
[ "$minos" = "$DEPTARGET" ] || { echo "FAIL: minos $minos != $DEPTARGET" >&2; exit 1; }

cp "$BIN/ffmpeg" "$BIN/ffprobe" "$OUT_DIR/"
echo "✓ $(du -h "$OUT_DIR/ffmpeg" | cut -f1) ffmpeg, $(du -h "$OUT_DIR/ffprobe" | cut -f1) ffprobe → $OUT_DIR"
echo "  license: $(printf '%s' "$cfg" >/dev/null; "$BIN/ffmpeg" -hide_banner -L 2>/dev/null | head -1)"
shasum -a 256 "$OUT_DIR/ffmpeg" "$OUT_DIR/ffprobe"
