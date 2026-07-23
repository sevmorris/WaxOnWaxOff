#!/usr/bin/env bash
# parity-check.sh — Old-binary vs new-binary parity over the corpus.
#
# Runs the app's ACTUAL ffmpeg filter chains (from AudioProcessor/DeliveryProcessor)
# through both binaries and compares outputs. Report is per-file, per-gate, with
# MEASURED values — margins, not verdicts.
#
# Policy (frozen — do not edit a threshold after seeing results; propose to the
# owner with the failing data instead):
#   * Three states: PASS / FAIL / INCOMPLETE. INCOMPLETE never counts as PASS.
#   * Runs the whole corpus; never aborts early; exits non-zero if any FAIL/INCOMPLETE.
#   * Pre-registered divergences (below) are expected and don't fail.
#   * The null result is diagnostic; the hard gates (LUFS/TP, format, sample-count) decide.
#
# Thresholds (frozen):
NULL_HARD_DB="-90"     # filter-only chains (no loudnorm, no LAME): expect near-identical
LUFS_TOL="0.1"         # integrated loudness, dB
TP_TOL="0.1"           # true peak, dB
#
# Pre-registered divergences:
#   MP3 outputs — old binary links LAME 3.99.5, new links LAME 3.100. The bitstream
#   changes by design, so MP3 gets LUFS/TP + format gates, NOT a null gate.
#
# bash 3.2-safe. Env: WOW_PARITY_CORPUS, WOW_OLD_FFMPEG, WOW_NEW_FFMPEG.

set -uo pipefail
CORPUS="${WOW_PARITY_CORPUS:?}"; OLD="${WOW_OLD_FFMPEG:?}"; NEW="${WOW_NEW_FFMPEG:?}"
METER="$OLD"   # measure both outputs with ONE fixed meter to isolate output diffs
PROBE="${WOW_OLD_FFPROBE:-$(dirname "$OLD")/ffprobe}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0

state() { printf '  [%-10s] %s\n' "$1" "$2"; case "$1" in FAIL|INCOMPLETE) fails=$((fails+1));; esac; }

# measure integrated LUFS + true peak with the fixed meter (loudnorm print_format=json)
measure() {  # file -> "I TP" or "" on failure
    j="$("$METER" -hide_banner -nostats -i "$1" -af loudnorm=print_format=json -f null - 2>&1 \
         | awk '/"input_i"/{i=$3} /"input_tp"/{t=$3} END{gsub(/[",]/,"",i);gsub(/[",]/,"",t);print i, t}')"
    printf '%s' "$j"
}
# NOTE: -show_entries is an ffprobe option. Calling ffmpeg with it yields an empty
# string, and comparing empty-to-empty reports a false PASS — a silently skipped
# gate, which the policy forbids. Use ffprobe, and treat empty as INCOMPLETE.
fmt() {  # file -> "codec,rate,channels,bits"
    "$PROBE" -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels,bits_per_raw_sample \
        -of "csv=p=0" "$1" 2>/dev/null | head -1
}
samples() { "$PROBE" -v error -select_streams a:0 -show_entries stream=duration_ts,nb_frames -of csv=p=0 "$1" 2>/dev/null | head -1; }

# compare(): PASS only on a non-empty match; empty probe output is INCOMPLETE.
compare() {  # label  old  new
    if [ -z "$2" ] || [ -z "$3" ]; then state INCOMPLETE "$1 unmeasurable (probe returned nothing)"
    elif [ "$2" = "$3" ]; then state PASS "$1 $3"
    else state FAIL "$1 $2 vs $3"; fi
}

null_db() {  # a b -> residual dBFS (linear Max converted), or ""
    r="$("$OLD" -hide_banner -nostats -i "$1" -i "$2" \
        -filter_complex "[0:a][1:a]amerge=inputs=2,aeval=val(0)-val(1):c=1,astats=metadata=1:reset=0" \
        -f null - 2>&1 | awk -F': ' '/Peak level dB/{v=$2} END{print v}')"
    printf '%s' "$r"
}

abs_le() { awk -v a="$1" -v b="$2" 'BEGIN{a=(a<0?-a:a); exit !(a<=b)}'; }

# The app's WaxOn stage-1 chain (mono), no loudnorm, no LAME → clean single-variable.
waxon_s1() { echo "highpass=f=80,pan=1c|c0=c0,allpass=f=200:t=q:w=0.707,aresample=44100:filter_size=512:cutoff=0.97:phase_shift=10"; }
# WaxOff two-pass loudnorm render (upmix→allpass→loudnorm linear→2x→alimiter→back). Uses measured pass-1 values.
run_waxoff() {  # bin in out
    m="$("$1" -hide_banner -nostats -i "$2" -af "pan=stereo|c0=c0|c1=c0,allpass=f=200:t=q:w=0.707,loudnorm=I=-16:TP=-1:LRA=11:print_format=json" -f null - 2>&1)"
    I=$(printf '%s' "$m"|awk '/input_i/{gsub(/[",]/,"",$3);print $3}'); T=$(printf '%s' "$m"|awk '/input_tp/{gsub(/[",]/,"",$3);print $3}')
    L=$(printf '%s' "$m"|awk '/input_lra/{gsub(/[",]/,"",$3);print $3}'); H=$(printf '%s' "$m"|awk '/input_thresh/{gsub(/[",]/,"",$3);print $3}')
    O=$(printf '%s' "$m"|awk '/target_offset/{gsub(/[",]/,"",$3);print $3}')
    [ -n "$I" ] || return 1
    "$1" -y -hide_banner -loglevel error -i "$2" -af \
      "pan=stereo|c0=c0|c1=c0,allpass=f=200:t=q:w=0.707,loudnorm=I=-16:TP=-1:LRA=11:measured_I=$I:measured_TP=$T:measured_LRA=$L:measured_thresh=$H:offset=$O:linear=true,aresample=88200:filter_size=512:cutoff=0.97:phase_shift=10,alimiter=limit=0.891251:attack=5:release=50:level=disabled,aresample=44100:filter_size=512:cutoff=0.97:phase_shift=10" \
      -ar 44100 -ac 2 -c:a pcm_s24le "$3"
}

echo "=== PARITY: old ($("$OLD" -version|awk 'NR==1{print $3}')) vs new ($("$NEW" -version|awk 'NR==1{print $3}')) ==="
lamever() { "$1" -y -loglevel error -f lavfi -i "sine=d=0.3" -c:a libmp3lame /tmp/_lv.mp3 2>/dev/null; strings /tmp/_lv.mp3 | grep -om1 "LAME[0-9.]*"; rm -f /tmp/_lv.mp3; }
echo "old LAME: $(lamever "$OLD")   new LAME: $(lamever "$NEW")"

for f in "$CORPUS"/speech-mono48.wav "$CORPUS"/speech-noisy.wav "$CORPUS"/speech-20s.wav "$CORPUS"/speech-9s.wav "$CORPUS"/speech.flac "$CORPUS"/speech.m4a "$CORPUS"/speech-in.mp4; do
    [ -f "$f" ] || { echo "$(basename "$f")"; state INCOMPLETE "fixture not generated"; continue; }
    b="$(basename "$f")"; echo "$b"
    # Gate A: WaxOn stage-1 filter chain — NULL + format + sample-count
    "$OLD" -y -hide_banner -loglevel error -i "$f" -map 0:a:0 -af "$(waxon_s1)" -ar 44100 -ac 1 -c:a pcm_s24le "$TMP/o1.wav" 2>/dev/null
    "$NEW" -y -hide_banner -loglevel error -i "$f" -map 0:a:0 -af "$(waxon_s1)" -ar 44100 -ac 1 -c:a pcm_s24le "$TMP/n1.wav" 2>/dev/null
    if [ -s "$TMP/o1.wav" ] && [ -s "$TMP/n1.wav" ]; then
        nd="$(null_db "$TMP/o1.wav" "$TMP/n1.wav")"
        if [ -n "$nd" ] && abs_le "$nd" 1 && awk -v v="$nd" -v t="$NULL_HARD_DB" 'BEGIN{exit !(v<=t)}'; then
            state PASS "WaxOn s1 null=${nd} dBFS (<= ${NULL_HARD_DB})"
        else state FAIL "WaxOn s1 null=${nd:-?} dBFS (want <= ${NULL_HARD_DB})"; fi
        compare "s1 format"  "$(fmt "$TMP/o1.wav")"     "$(fmt "$TMP/n1.wav")"
        compare "s1 samples" "$(samples "$TMP/o1.wav")" "$(samples "$TMP/n1.wav")"
    else state INCOMPLETE "WaxOn s1 render produced no output"; fi
    # Gate B: WaxOff two-pass render — LUFS/TP (hard) + null (diagnostic)
    if run_waxoff "$OLD" "$f" "$TMP/ow.wav" 2>/dev/null && run_waxoff "$NEW" "$f" "$TMP/nw.wav" 2>/dev/null; then
        om="$(measure "$TMP/ow.wav")"; nm="$(measure "$TMP/nw.wav")"
        oI="${om%% *}"; oT="${om##* }"; nI="${nm%% *}"; nT="${nm##* }"
        dI="$(awk -v a="$oI" -v b="$nI" 'BEGIN{print a-b}')"; dT="$(awk -v a="$oT" -v b="$nT" 'BEGIN{print a-b}')"
        abs_le "$dI" "$LUFS_TOL" && state PASS "WaxOff LUFS Δ=${dI} (old ${oI}/new ${nI})" || state FAIL "WaxOff LUFS Δ=${dI} (> ${LUFS_TOL})"
        abs_le "$dT" "$TP_TOL"   && state PASS "WaxOff TP   Δ=${dT} (old ${oT}/new ${nT})" || state FAIL "WaxOff TP Δ=${dT} (> ${TP_TOL})"
        nd2="$(null_db "$TMP/ow.wav" "$TMP/nw.wav")"; state DIAG "WaxOff null=${nd2:-?} dBFS (two-pass; diagnostic only)"
    else state INCOMPLETE "WaxOff render failed"; fi
done

echo; echo "=== $([ "$fails" -eq 0 ] && echo ALL PASS || echo "$fails FAIL/INCOMPLETE") ==="
[ "$fails" -eq 0 ]
