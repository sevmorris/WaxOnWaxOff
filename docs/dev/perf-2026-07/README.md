# WaxOff performance work — gate evidence (2026-07-08/09)

Artifacts from the perf audit and fix session behind the `perf/waxoff-2026-07`
branch. Each file below is the evidence for a specific commit's merge gate.
Machine for all numbers: M3 Pro, 12 cores (6P+6E), bundled FFmpeg 8.0 arm64.

| file | proves | gate for |
|---|---|---|
| [meter-agreement.md](meter-agreement.md) | loudnorm↔ebur128 delta tables, the rhino-MP3 failure, 8×/16× oversampled reference, WAV-side re-run | `4c9ce5b` (hybrid WAV verification) |
| [a2-parity-baseline.json](a2-parity-baseline.json) | pre-merge full-precision stats + FNV-1a waveform bucket hashes the merged single-decode pass was compared against (bit-exact) | `89637f0` (single-decode merge) |
| [vdsp-parity-report.txt](vdsp-parity-report.txt) | vDSP vs scalar analyzer: 0.000000 deltas across the 9-file corpus; per-file timings; 60-min speedup 82.3 → 3.96 s | `51c1a26` (vDSP analyzer) |
| [waveform-parity-report.txt](waveform-parity-report.txt) | bit-exact waveform buckets across the corpus; 5.0× speedup; combined-pass timing | `43bb426` (vDSP waveform) |
| [capgate-history.md](capgate-history.md) | all 8×30-min batch runs incl. the two failed cap-raise gates and the pool-sizing lesson | `ead64e2`, `0efa96a`, `9ae7084` |
| [capgate-final.txt](capgate-final.txt) | raw report of the final passing cap gate (381.7 s = 1.64×) | `9ae7084` (cap raise) |
| [wrapup-single-report.txt](wrapup-single-report.txt) | single 60-min confirmation: blocking 422.6 s vs ~426 projected, settled 498.5 s vs ~501 projected | wrap-up |
| [meter_agreement.sh](meter_agreement.sh) | re-runnable loudnorm-vs-ebur128 comparison script (edit the hardcoded ffmpeg path if the checkout moves) | tooling |

## Regenerating the benchmark corpus

The audio inputs are not stored (multi-GB). Recipes, with the bundled
`WaxOnWaxOff/ffmpeg`:

Benchmark inputs (pink noise + slow tremolo; 3600 for 60-min, 1800 for 30-min;
`-ac 1` for mono variants; copies of one file are fine for batch inputs):

    ffmpeg -nostdin -hide_banner -loglevel error -y \
      -f lavfi -i "anoisesrc=color=pink:sample_rate=44100:amplitude=0.15:duration=1800" \
      -af "tremolo=f=0.1:d=0.6" -ac 2 -c:a pcm_s16le st30.wav

Hot inter-sample-peak file (fs/4 sine at 45° phase — sample peaks ~3 dB under
true peak):

    ffmpeg -nostdin -hide_banner -loglevel error -y \
      -f lavfi -i "aevalsrc=0.95*sin(2*PI*11025*t+PI/4):sample_rate=44100:duration=120" \
      -ac 2 -c:a pcm_s16le isp_hot.wav

Real-material corpus: copies of "NPR Dec 15 1998.wav" (voice-dominant) and
"Rhino Chasers.wav" (music) from ~/Music/Everything is Changing field
recordings, processed through WaxOff at defaults ("Both") to produce the
delivered WAV+MP3 pairs the meter tables reference.

Oversampled true-peak reference used to arbitrate the meters:

    ffmpeg -i FILE -af "aresample=352800:filter_size=512:cutoff=0.985,astats=measure_overall=Peak_level:measure_perchannel=none" -f null -

Per-invocation stage timing for any future audit: WaxPerfLog
(`defaults write io.github.sevmorris.WaxOnWaxOff WaxPerfLog -bool YES`,
unified log category "Perf" — use `/usr/bin/log` explicitly if your shell
shadows `log`).
