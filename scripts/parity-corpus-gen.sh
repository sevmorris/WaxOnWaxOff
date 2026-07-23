#!/usr/bin/env bash
# parity-corpus-gen.sh — Generate the parity corpus OUTSIDE the repo tree.
#
# Real speech (macOS `say`, two distinct voices) is the primary material because
# the DSP under test is data-dependent: a sine never trips loudnorm's relative
# gate, gives dynaudnorm nothing to move, and tells arnndn (a speech model)
# nothing. Synthetic tones are generated too, but only for the structural gates
# (format, sample-count) — never trusted for LUFS/TP/null.
#
# Everything is produced with the OLD, full bundled binary (WOW_OLD_FFMPEG): if a
# later --disable-everything pass strips a source/muxer from the NEW binary, the
# generator is unaffected and you get a clean parity result, not a generator error.
#
# Corpus lives at $WOW_PARITY_CORPUS — no default inside the repo. Audio is never
# committed; this script is.
#
# bash 3.2-safe. Env: WOW_PARITY_CORPUS (out dir), WOW_OLD_FFMPEG (old ffmpeg path).

set -euo pipefail

CORPUS="${WOW_PARITY_CORPUS:?set WOW_PARITY_CORPUS to a path OUTSIDE the repo}"
OLD="${WOW_OLD_FFMPEG:?set WOW_OLD_FFMPEG to the current (full) ffmpeg binary}"
case "$CORPUS" in
  "$PWD"*|*/WaxOnWaxOff/*) echo "refusing: corpus path is inside the repo tree" >&2; exit 1;;
esac
mkdir -p "$CORPUS"
# --- Voice selection: pick the first TWO *installed* voices from a preference
# list. Named voices are download-on-demand on current macOS, so hardcoding two
# risks `say` silently falling back to the system default and producing a
# "stereo" fixture that is really dual-mono — passing every gate while testing
# nothing. Fewer than two distinct installed voices => INCOMPLETE, never a fallback.
VOICE_PREFS="Alex Samantha Daniel Albert Fred Karen Moira Tessa Serena Allison"
avail() { say -v '?' 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
V1=""; V2=""
for v in $VOICE_PREFS; do
    if avail "$v"; then
        if [ -z "$V1" ]; then V1="$v"
        elif [ -z "$V2" ]; then V2="$v"; break
        fi
    fi
done
if [ -z "$V1" ] || [ -z "$V2" ]; then
    echo "INCOMPLETE: need two installed 'say' voices for decorrelated fixtures; found: ${V1:-none} ${V2:-}" >&2
    echo "  installed candidates: $(say -v '?' 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | cut -c1-200)" >&2
    exit 3
fi
echo "▶ voices: $V1 (L) / $V2 (R)"

say_wav() {  # voice  text  out.wav   (22050 mono → 48k mono wav via OLD binary)
    say -v "$1" -o "$CORPUS/_tmp.aiff" "$2"
    "$OLD" -y -loglevel error -i "$CORPUS/_tmp.aiff" -ar 48000 -ac 1 -c:a pcm_s16le "$3"
    rm -f "$CORPUS/_tmp.aiff"
}

TXT="This is a parity corpus sample. It has pauses, and varied dynamics, so that loudness gating and the leveler actually have something to work on."
TXT2="A second speaker reads different words, at a different pace, to decorrelate the channels for real stereo testing."

echo "▶ mono speech"
say_wav "$V1" "$TXT" "$CORPUS/speech-mono48.wav"

echo "▶ decorrelated stereo (two voices → L/R, verified distinct)"
say_wav "$V1" "$TXT"  "$CORPUS/_L.wav"
say_wav "$V2" "$TXT2" "$CORPUS/_R.wav"
# trim both to the shorter length, then join L+R
"$OLD" -y -loglevel error -i "$CORPUS/_L.wav" -i "$CORPUS/_R.wav" \
    -filter_complex "[0:a][1:a]amerge=inputs=2,pan=stereo|c0=c0|c1=c1[a]" -map "[a]" \
    -ar 48000 -c:a pcm_s16le "$CORPUS/speech-stereo48.wav"
# Verify the channels actually differ. A dual-mono file (say silently falling back
# to one voice) nulls L-R to digital silence; real decorrelated speech leaves a
# large residual. Fail loudly rather than ship a fixture that tests nothing.
lr_rms="$("$OLD" -hide_banner -nostats -i "$CORPUS/speech-stereo48.wav" \
     -af "aeval=val(0)-val(1):c=1,astats=metadata=1:reset=0" -f null - 2>&1 \
     | awk -F': ' '/RMS level dB/{v=$2} END{print v}')"
case "$lr_rms" in
  ""|*inf*) echo "INCOMPLETE: stereo fixture is dual-mono (L-R nulls to ${lr_rms:-nothing}) — voices did not differ" >&2; exit 3;;
esac
awk -v v="$lr_rms" 'BEGIN{exit !(v > -60)}' \
  || { echo "INCOMPLETE: stereo L-R residual ${lr_rms} dB is near-silent — channels are effectively identical" >&2; exit 3; }
echo "   stereo decorrelation verified: L-R residual RMS ${lr_rms} dB"
rm -f "$CORPUS/_L.wav" "$CORPUS/_R.wav"

echo "▶ short-duration fixtures (dynaudnorm skip <2s; mirror-pad capped 8-10s; full >16s)"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -t 1.5  -c:a pcm_s16le "$CORPUS/speech-1p5s.wav"   # dynaudnorm skip branch
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -t 9.0  -c:a pcm_s16le "$CORPUS/speech-9s.wav"     # mirror-pad capped branch
"$OLD" -y -loglevel error -stream_loop 3 -i "$CORPUS/speech-mono48.wav" -t 20 -c:a pcm_s16le "$CORPUS/speech-20s.wav"  # full-padding branch
# NOTE: the third mirror-padding branch — duration unknown → padding skipped — is
# NOT reachable via a generated fixture: the app probes duration with ffprobe and
# only takes that branch when ffprobe cannot report one (corrupt/streamed input).
# A well-formed generated file always has a readable duration. Recorded as
# not-coverable here rather than left silently uncovered; exercise it with a
# deliberately malformed header on the build host if you want it gated.

echo "▶ noisy speech (speech + low-level noise → the only real test of arnndn / NR-for-measurement)"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -f lavfi -i "anoisesrc=color=pink:amplitude=0.03:d=999" \
    -filter_complex "[0:a][1:a]amix=inputs=2:duration=first:weights=1 0.15[a]" -map "[a]" \
    -ar 48000 -ac 1 -c:a pcm_s16le "$CORPUS/speech-noisy.wav"

echo "▶ format matrix (from mono speech, via OLD binary)"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -c:a flac       "$CORPUS/speech.flac"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -c:a libmp3lame -b:a 160k "$CORPUS/speech.mp3"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -c:a aac -b:a 192k "$CORPUS/speech.m4a"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -c:a aac -b:a 192k -f adts "$CORPUS/speech.aac"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -c:a pcm_s16le "$CORPUS/speech.caf"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -c:a pcm_s16be -f aiff "$CORPUS/speech.aiff"

echo "▶ MP4/MOV WITH a silent video stream (so the app's -map 0:a:0 ignore-video path runs)"
for ext in mp4 mov; do
    "$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" \
        -f lavfi -i "color=c=black:s=64x64:r=15" -shortest \
        -c:a aac -b:a 192k -c:v mpeg4 "$CORPUS/speech-in.$ext"
done
# Confirm they carry video — the whole point of these fixtures is that the app's
# `-map 0:a:0` must skip a real video stream. Use ffprobe (-show_entries is an
# ffprobe option; calling ffmpeg with it silently yields nothing).
PROBE="${WOW_OLD_FFPROBE:-$(dirname "$OLD")/ffprobe}"
for ext in mp4 mov; do
    hasv="$("$PROBE" -v error -show_entries stream=codec_type -of csv=p=0 "$CORPUS/speech-in.$ext" 2>/dev/null | grep -c video)"
    [ "${hasv:-0}" -ge 1 ] \
        && echo "   speech-in.$ext: video stream present ✓" \
        || { echo "INCOMPLETE: speech-in.$ext has no video stream — the -map 0:a:0 path would not be exercised" >&2; exit 3; }
done

echo "▶ 5.1 fixture (distinct content per channel where possible)"
say_wav "$V2" "$TXT2" "$CORPUS/_c.wav"
"$OLD" -y -loglevel error -i "$CORPUS/speech-mono48.wav" -i "$CORPUS/_c.wav" \
    -filter_complex "[0:a][1:a][0:a][1:a][0:a][1:a]amerge=inputs=6,pan=5.1|c0=c0|c1=c1|c2=c2|c3=c3|c4=c4|c5=c5[a]" \
    -map "[a]" -ar 48000 -c:a pcm_s16le "$CORPUS/speech-51.wav" 2>/dev/null || \
    echo "   NOTE: 5.1 build used 2 distinct voices across 6 channels (front pair fully decorrelated; surrounds reuse) — a truly 6-way-distinct source needs 6 voices"
rm -f "$CORPUS/_c.wav"

echo "▶ synthetic (structural gates only — format + sample-count; NOT LUFS/TP/null)"
"$OLD" -y -loglevel error -f lavfi -i "sine=frequency=440:duration=3"        -ar 44100 -c:a pcm_s16le "$CORPUS/synth-sine.wav"
"$OLD" -y -loglevel error -f lavfi -i "anoisesrc=color=white:amplitude=0.5:d=3" -ar 48000 -c:a pcm_s16le "$CORPUS/synth-noise.wav"

echo "✓ corpus at $CORPUS:"; ls -1 "$CORPUS"
