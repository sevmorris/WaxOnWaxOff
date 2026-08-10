#!/usr/bin/env bash
# parity-check.sh — Old-binary vs new-binary parity over the whole corpus.
#
# Runs the app's ACTUAL ffmpeg filter chains (from AudioProcessor/DeliveryProcessor)
# through both binaries and compares outputs. Report is per-file, per-gate, with
# MEASURED values — margins, not verdicts.
#
# Policy (frozen — do not edit a threshold after seeing results; take the failing
# data to the owner instead):
#   * Three states: PASS / FAIL / INCOMPLETE. INCOMPLETE never counts as PASS.
#   * Runs EVERY fixture in the corpus; never aborts early; exits non-zero on any
#     FAIL or INCOMPLETE.
#   * Pre-registered divergences (below) are expected and do not fail.
#   * Null is diagnostic; LUFS/TP/format/sample-count are the hard gates.
#
# Thresholds (frozen):
NULL_HARD_DB="-90"     # filter chains that use neither loudnorm nor LAME
LUFS_TOL="0.1"
TP_TOL="0.1"
#
# Pre-registered divergences:
#   MP3 — old links LAME 3.99.5, new links LAME 3.100. The bitstream changes by
#   design: MP3 gets LUFS/TP + format gates, never a null gate.
#
# bash 3.2-safe. Env: WOW_PARITY_CORPUS, WOW_OLD_FFMPEG, WOW_NEW_FFMPEG.

set -uo pipefail
CORPUS="${WOW_PARITY_CORPUS:?}"; OLD="${WOW_OLD_FFMPEG:?}"; NEW="${WOW_NEW_FFMPEG:?}"
METER="$OLD"   # ONE fixed meter for both sides, so we measure output diffs not meter diffs
PROBE="${WOW_OLD_FFPROBE:-$(dirname "$OLD")/ffprobe}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; incomplete=0

state() {
    printf '  %-11s %s\n' "[$1]" "$2"
    case "$1" in
        PASS) pass=$((pass+1));;
        FAIL) fail=$((fail+1));;
        INCOMPLETE) incomplete=$((incomplete+1));;
    esac
}

# Null residual, CHANNEL-SAFE. Inverting one side and summing works at any channel
# count. (A previous version amerge'd the two files and subtracted channel 0 from
# channel 1 — on stereo inputs that compares the OLD file's L against its own R,
# which is identically zero for a dual-mono upmix and reported a false -inf.)
null_db() {
    "$METER" -hide_banner -nostats -i "$1" -i "$2" \
        -filter_complex "[1:a]volume=-1[inv];[0:a][inv]amix=inputs=2:normalize=0,astats=metadata=1:reset=0" \
        -f null - 2>&1 | awk -F': ' '/Peak level dB/{v=$2} END{print v}'
}
measure() {  # -> "I TP"
    "$METER" -hide_banner -nostats -i "$1" -af loudnorm=print_format=json -f null - 2>&1 \
        | awk '/"input_i"/{i=$3} /"input_tp"/{t=$3} END{gsub(/[",]/,"",i);gsub(/[",]/,"",t);print i, t}'
}
fmt() { "$PROBE" -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$1" 2>/dev/null | head -1; }
samples() { "$PROBE" -v error -select_streams a:0 -show_entries stream=duration_ts -of csv=p=0 "$1" 2>/dev/null | head -1; }
abs_le() { awk -v a="$1" -v b="$2" 'BEGIN{a=(a<0?-a:a); exit !(a<=b)}'; }

compare() {  # label old new   — empty is INCOMPLETE, never a false PASS
    if [ -z "$2" ] || [ -z "$3" ]; then state INCOMPLETE "$1 unmeasurable"
    elif [ "$2" = "$3" ]; then state PASS "$1 = $3"
    else state FAIL "$1: old=$2 new=$3"; fi
}
gate_loud() {  # label oldfile newfile
    om="$(measure "$2")"; nm="$(measure "$3")"
    oI="${om%% *}"; oT="${om##* }"; nI="${nm%% *}"; nT="${nm##* }"
    if [ -z "$oI" ] || [ -z "$nI" ]; then state INCOMPLETE "$1 LUFS/TP unmeasurable"; return; fi
    dI="$(awk -v a="$oI" -v b="$nI" 'BEGIN{printf "%.4f", a-b}')"
    dT="$(awk -v a="$oT" -v b="$nT" 'BEGIN{printf "%.4f", a-b}')"
    if abs_le "$dI" "$LUFS_TOL"; then
        state PASS "$1 LUFS Δ=${dI} (old ${oI} new ${nI})"
    else
        state FAIL "$1 LUFS Δ=${dI} > ${LUFS_TOL}"
    fi
    if abs_le "$dT" "$TP_TOL"; then
        state PASS "$1 TP   Δ=${dT} (old ${oT} new ${nT})"
    else
        state FAIL "$1 TP Δ=${dT} > ${TP_TOL}"
    fi
}
gate_null() {  # label oldfile newfile
    nd="$(null_db "$2" "$3")"
    if [ -z "$nd" ]; then state INCOMPLETE "$1 null unmeasurable"
    elif [ "$nd" = "-inf" ]; then state PASS "$1 null = -inf (bit-identical)"
    elif awk -v v="$nd" -v t="$NULL_HARD_DB" 'BEGIN{exit !(v<=t)}'; then state PASS "$1 null = ${nd} dBFS (<= ${NULL_HARD_DB})"
    else state FAIL "$1 null = ${nd} dBFS (want <= ${NULL_HARD_DB})"; fi
}

WAXON_S1="highpass=f=80,pan=1c|c0=c0,allpass=f=200:t=q:w=0.707,aresample=44100:filter_size=512:cutoff=0.97:phase_shift=10"
run_waxoff() {  # bin in out
    local m I T L H O CHAIN
    m="$("$1" -hide_banner -nostats -i "$2" -af "pan=stereo|c0=c0|c1=c0,allpass=f=200:t=q:w=0.707,loudnorm=I=-16:TP=-1:LRA=11:print_format=json" -f null - 2>&1)"
    I=$(printf '%s' "$m"|awk '/input_i/{gsub(/[",]/,"",$3);print $3}')
    T=$(printf '%s' "$m"|awk '/input_tp/{gsub(/[",]/,"",$3);print $3}')
    L=$(printf '%s' "$m"|awk '/input_lra/{gsub(/[",]/,"",$3);print $3}')
    H=$(printf '%s' "$m"|awk '/input_thresh/{gsub(/[",]/,"",$3);print $3}')
    O=$(printf '%s' "$m"|awk '/target_offset/{gsub(/[",]/,"",$3);print $3}')
    [ -n "$I" ] || return 1
    CHAIN="pan=stereo|c0=c0|c1=c0,allpass=f=200:t=q:w=0.707,loudnorm=I=-16:TP=-1:LRA=11:measured_I=${I}:measured_TP=${T}:measured_LRA=${L}:measured_thresh=${H}:offset=${O}:linear=true,aresample=88200:filter_size=512:cutoff=0.97:phase_shift=10,alimiter=limit=0.891251:attack=5:release=50:level=disabled,aresample=44100:filter_size=512:cutoff=0.97:phase_shift=10"
    "$1" -y -hide_banner -loglevel error -i "$2" -af "$CHAIN" -ar 44100 -ac 2 -c:a pcm_s24le "$3"
}
run_mp3() { "$1" -y -hide_banner -loglevel error -i "$2" \
    -af "aresample=88200:filter_size=512:cutoff=0.97:phase_shift=10,alimiter=limit=0.794328:attack=1:release=20:level=disabled,aresample=44100:filter_size=512:cutoff=0.97:phase_shift=10" \
    -c:a libmp3lame -b:a 160k -ar 44100 "$3"; }

lamever() { "$1" -y -loglevel error -f lavfi -i "sine=d=0.3" -c:a libmp3lame "$TMP/_lv.mp3" 2>/dev/null; strings "$TMP/_lv.mp3" | grep -om1 "LAME[0-9.]*"; rm -f "$TMP/_lv.mp3"; }
echo "=== PARITY  old=$("$OLD" -version|awk 'NR==1{print $3}')  new=$("$NEW" -version|awk 'NR==1{print $3}') ==="
echo "=== LAME    old=$(lamever "$OLD")  new=$(lamever "$NEW")  (MP3 divergence pre-registered) ==="

# EVERY fixture in the corpus — no hand-picked subset.
for f in "$CORPUS"/*; do
    case "$f" in *.wav|*.mp3|*.flac|*.m4a|*.aac|*.caf|*.aiff|*.mp4|*.mov) ;; *) continue;; esac
    b="$(basename "$f")"; echo "$b"

    # --- WaxOn stage 1: null + format + samples + LUFS/TP ---
    "$OLD" -y -hide_banner -loglevel error -i "$f" -map 0:a:0 -af "$WAXON_S1" -ar 44100 -ac 1 -c:a pcm_s24le "$TMP/o1.wav" 2>/dev/null
    "$NEW" -y -hide_banner -loglevel error -i "$f" -map 0:a:0 -af "$WAXON_S1" -ar 44100 -ac 1 -c:a pcm_s24le "$TMP/n1.wav" 2>/dev/null
    if [ -s "$TMP/o1.wav" ] && [ -s "$TMP/n1.wav" ]; then
        gate_null "WaxOn s1" "$TMP/o1.wav" "$TMP/n1.wav"
        compare   "WaxOn s1 format"  "$(fmt "$TMP/o1.wav")"     "$(fmt "$TMP/n1.wav")"
        compare   "WaxOn s1 samples" "$(samples "$TMP/o1.wav")" "$(samples "$TMP/n1.wav")"
        gate_loud "WaxOn s1" "$TMP/o1.wav" "$TMP/n1.wav"
    else state INCOMPLETE "WaxOn s1 produced no output"; fi

    # --- WaxOff two-pass render: null + format + samples + LUFS/TP ---
    if run_waxoff "$OLD" "$f" "$TMP/ow.wav" 2>/dev/null && run_waxoff "$NEW" "$f" "$TMP/nw.wav" 2>/dev/null; then
        gate_null "WaxOff" "$TMP/ow.wav" "$TMP/nw.wav"
        compare   "WaxOff format"  "$(fmt "$TMP/ow.wav")"     "$(fmt "$TMP/nw.wav")"
        compare   "WaxOff samples" "$(samples "$TMP/ow.wav")" "$(samples "$TMP/nw.wav")"
        gate_loud "WaxOff" "$TMP/ow.wav" "$TMP/nw.wav"
    else state INCOMPLETE "WaxOff render failed"; fi

    # --- MP3: format + LUFS/TP only (LAME version divergence pre-registered) ---
    if run_mp3 "$OLD" "$f" "$TMP/o.mp3" 2>/dev/null && run_mp3 "$NEW" "$f" "$TMP/n.mp3" 2>/dev/null; then
        compare   "MP3 format" "$(fmt "$TMP/o.mp3")" "$(fmt "$TMP/n.mp3")"
        gate_loud "MP3" "$TMP/o.mp3" "$TMP/n.mp3"
        state PREREG "MP3 null skipped — LAME 3.99.5 vs 3.100 (declared before the run)"
    else state INCOMPLETE "MP3 encode failed"; fi
done

echo
echo "=== PASS=$pass  FAIL=$fail  INCOMPLETE=$incomplete ==="
[ "$fail" -eq 0 ] && [ "$incomplete" -eq 0 ]
