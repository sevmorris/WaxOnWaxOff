# Meter agreement: loudnorm measurement vs ebur128 — gate evidence for ef58d71

Corpus: synthetic (10-min pink-noise stereo/mono, fs/4+45° hot-ISP sine, a
rendered −18 LUFS delivery WAV and its MP3) plus two real recordings processed
through the actual pipeline at default settings ("real_voice_60min_mono": 60-min mono
broadcast, voice-dominant; "real_music_31min_stereo": 31-min stereo band recording).
Recorded from the fix-session gate runs of 2026-07-08/09 (M3 Pro, bundled
FFmpeg 8.0). Re-runnable via meter_agreement.sh in this directory.

## Original gate run (both meters on every file; ebur128 stderr summary, 1-decimal)

| file | ln I/TP/LRA | eb I/TP/LRA | ΔI | ΔTP | verdict |
|---|---|---|---|---|---|
| stereo pink noise | −33.96/−19.96/6.30 | −33.9/−20.0/6.4 | 0.06 | 0.04 | pass |
| mono pink noise | −33.97/−16.94/6.30 | −33.9/−16.9/6.4 | 0.07 | 0.04 | pass |
| hot-ISP fs/4 sine | −0.15/−2.87/0.00 | −0.1/−2.9/0.0 | 0.05 | 0.03 | pass |
| rendered WAV | −18.02/−3.40/6.30 | −18.0/−3.4/6.4 | 0.02 | 0.00 | pass |
| rendered MP3 | −18.68/−4.22/6.30 | −18.7/−4.2/6.4 | 0.02 | 0.02 | pass |
| real_voice_60min_mono WAV | −18.00/−3.64/3.60 | −18.0/−3.6/3.6 | 0.00 | 0.04 | pass |
| real_voice_60min_mono MP3 | −18.44/−4.08/3.70 | −18.4/−4.1/3.6 | 0.04 | 0.02 | pass |
| real_music_31min_stereo WAV | −18.10/−1.00/16.20 | −18.1/−1.0/16.0 | 0.00 | 0.00 | pass |
| **real_music_31min_stereo MP3** | **−18.54/−1.98/16.20** | **−18.5/−2.1/16.0** | 0.04 | **0.12** | **FAIL** |

Tolerance: ΔI ≤ 0.1 LU, ΔTP ≤ 0.1 dBTP.

## Failure characterization (full-precision ebur128 frame metadata)

| file | loudnorm TP | ebur128 TP (frame metadata) | ΔTP |
|---|---|---|---|
| real_music_31min_stereo MP3 | −1.98 | −2.136 | **0.156** (genuine, not display rounding) |
| real_music_31min_stereo WAV | −1.00 | −1.002 | 0.002 |
| real_voice_60min_mono MP3 | −4.08 | −4.082 | 0.002 |
| real_voice_60min_mono WAV | −3.64 | −3.649 | 0.009 |

Oversampled reference on the failing file (decode → aresample filter_size=512
cutoff=0.985 → astats peak):

| oversample | reference true peak |
|---|---|
| 8× (352.8 kHz) | −1.977255 dBFS |
| 16× (705.6 kHz) | −1.977255 dBFS (converged) |

Conclusion: loudnorm (−1.98) is accurate within 0.003 dB; ebur128's fixed 4×
BS.1770 interpolator underreads this hot music MP3 by 0.156 dB. loudnorm's
internal 192 kHz resample (4.35× at 44.1 kHz) resolves peaks the 4× polyphase
misses. Hence the hybrid: ebur128 (cheap, ≤0.009 dB agreement) for linear-PCM
WAV verification only; loudnorm retained for lossy-decoded MP3 verification.
The synthetic hot-ISP file did NOT expose this — both meters undershoot
band-limited pathology identically; only real broadband music through a real
MP3 decode differentiated the interpolators.

## WAV-side gate re-run against the final hybrid diff (full precision)

| WAV | ln I/TP | eb I/TP | ΔI | ΔTP |
|---|---|---|---|---|
| stereo pink noise | −33.96/−19.96 | −33.900/−20.000 | 0.060 | 0.040 |
| mono pink noise | −33.97/−16.94 | −33.903/−16.954 | 0.067 | 0.014 |
| hot-ISP sine | −0.15/−2.87 | −0.110/−2.865 | 0.040 | 0.005 |
| rendered WAV | −18.02/−3.40 | −17.973/−3.401 | 0.047 | 0.001 |
| real_voice_60min_mono WAV | −18.00/−3.64 | −17.964/−3.649 | 0.036 | 0.009 |
| real_music_31min_stereo WAV | −18.10/−1.00 | −18.065/−1.002 | 0.035 | 0.002 |

All within tolerance; max ΔI 0.067 LU, max ΔTP 0.040 dB.
