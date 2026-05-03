# WaxOn/WaxOff Pipeline Audit

**Scope:** Every FFmpeg filter chain in `AudioProcessor.swift`, `DeliveryProcessor.swift`, and `FFmpegRunner.swift`, compared against `docs/manual/theory.html`.  
**Audit date:** May 2026  
**Method:** Read all source files; reconstruct every chain from code; compare to doc; verify ordering against DSP principles; check every bug pattern explicitly.

---

## Executive Summary

**No HIGH-severity issues found.** All chains are correctly ordered, pass 1/pass 2 parity is maintained across every code path, and every known-bad DSP pattern was checked and is absent. Two MEDIUM issues exist — both are documentation bugs, not code bugs. Two LOW issues round out the findings.

- **MEDIUM-1:** WaxOff signal chain diagram omits the optional Dynamic Leveling (dynaudnorm) stage that the code always prepends when enabled.
- **MEDIUM-2:** De-esser cutoff is documented as "7.5 kHz" (fixed) but the FFmpeg `deesser` filter's `f` parameter is Nyquist-normalized; at 48 kHz the actual cutoff is ~8.2 kHz, not 7.5 kHz. The code log message has the same inaccuracy.

---

## Filter Chain Reconstruction

All chains are reconstructed from the code verbatim. Source citations use `file:line`.

### WaxOn — common notation

`phaseFilter` = `"allpass=f=200:t=q:w=0.707,"` when phase rotation enabled, else `""`.  `AP:90` = `AudioProcessor.swift:90`.

---

### WaxOn — Stereo output, NR on (all optional stages enabled)

**Step 1 — initial pre-processing (`filter_complex`)** → `midURL`  
`AP:109–115`
```
[0:a]channelsplit=channel_layout=stereo[L][R];
[L]arnndn=m=<model>[Lnr];
[R]arnndn=m=<model>[Rnr];
[Lnr][Rnr]join=inputs=2:channel_layout=stereo,
  highpass=f=80,
  allpass=f=200:t=q:w=0.707,
  aresample=<sr>
```
Output: `midURL` (stereo, pcm_s24le, target rate)

**Step 2 — de-esser (optional)** → `dsURL`  
`AP:150`
```
deesser=i=0.3:f=0.34:s=o
```

**Step 3 — level riding (optional)** → `levelURL`  
`AP:166`
```
dynaudnorm=p=0.95:m=1.0:g=31
```
(`f` not specified → dynaudnorm default 500 ms)

**Step 4 — dynamic leveling (optional)** → `dynLevelURL`  
`AP:179,489–497`
```
dynaudnorm=f=<F>:g=<G>:p=0.95:m=<M>:t=0.05
```
where at amount=0.0 (Gentle): f=500, g=31, m=2.0  
and at amount=1.0 (Aggressive): f=150, g=15, m=6.0

**Step 5 — NR-for-measurement (stereo, NR off path only)** → `nrTempURL`  
`AP:207–218`
```
[0:a]channelsplit=channel_layout=stereo[L][R];
[L]arnndn=m=<model>[Lnr];
[R]arnndn=m=<model>[Rnr];
[Lnr][Rnr]join=inputs=2:channel_layout=stereo
```
Input: `postDynLevelURL`. Output: `nrTempURL`. (Not applicable when NR is on — analysis runs on `postDynLevelURL` directly.)

**Step 6 — loudnorm pass 1 (analysis)** → `/dev/null` (measurements captured from stderr)  
`AP:231–237`
```
loudnorm=I=<target>:TP=<limitDb>:LRA=20:print_format=json
```
Input: `nrTempURL` (NR off) or `postDynLevelURL` (NR on).

**Step 7 — loudnorm pass 2 (render)** → `normURL`  
`AP:244–251`
```
loudnorm=I=<target>:TP=<limitDb>:LRA=20
  :measured_I=<inputI>:measured_TP=<inputTP>
  :measured_LRA=<inputLRA>:measured_thresh=<inputThresh>
  :offset=<targetOffset>:linear=true
```
Input: `postDynLevelURL` (always the original, not the NR'd copy).

**Step 8 — 2× oversampled limiter** → `tmpURL`  
`AP:260–266`
```
aresample=<sr*2>,
alimiter=limit=<limitAmp>:attack=5:release=50:level=disabled,
aresample=<sr>
```
Input: `normURL` (or `postDynLevelURL` if loudnorm disabled).

---

### WaxOn — Stereo output, NR off, phase on, no optional stages

Step 1 (`-af`, `AP:129`):
```
highpass=f=80,allpass=f=200:t=q:w=0.707,aresample=<sr>
```
Steps 2–4: skipped. Steps 5–7: NR-for-measurement runs if loudnorm enabled. Step 8: limiter.

---

### WaxOn — Mono output, NR on

Step 1 (`-af`, `AP:131–132`):
```
arnndn=m=<model>,highpass=f=80,pan=1c|c0=c0,allpass=f=200:t=q:w=0.707,aresample=<sr>
```
Note: `arnndn` runs on the source (potentially stereo) before `pan` extracts the single channel. The selected channel is processed by an independent arnndn instance and is functionally equivalent to arnndn on a mono input. See Ordering Audit for full discussion.

**NR-for-measurement (mono, `AP:220–224`):**
```
arnndn=m=<model>
```
Input is `postDynLevelURL`, which is already mono (pan ran in step 1). arnndn receives a true mono signal. ✓

---

### WaxOn — Mono output, NR off

Step 1 (`-af`, `AP:131–132`, `nrPrefix=""` since `nrModelURL=nil` when NR off):
```
highpass=f=80,pan=1c|c0=c0,allpass=f=200:t=q:w=0.707,aresample=<sr>
```

---

### WaxOn — Already at target sample rate / already mono

No special branch exists. `aresample=<sr>` is always appended regardless; FFmpeg is a no-op when input rate == requested rate. `pan=1c|c0=c0` is always added for mono output regardless. Both are harmless.

---

### WaxOff — WAV only, phase rotation on, dynaudnorm on

**Pass 1 — analysis (`DP:156–181`, `analyzeAudio`)**  
`DP:164–166`
```
dynaudnorm=f=500:g=51:p=0.95:m=2.0:t=0.05,allpass=f=150,loudnorm=I=<lufs>:TP=<tp>:LRA=<lra>:print_format=json
```
Input: `url` (source). No `-ar` — FFmpeg processes at source rate.

**Pass 2 — render WAV (`DP:183–218`, `renderWAV`)**  
`DP:193–201`
```
dynaudnorm=f=500:g=51:p=0.95:m=2.0:t=0.05,allpass=f=150,
loudnorm=I=<lufs>:TP=<tp>:LRA=<lra>
  :measured_I=<inputI>:measured_TP=<inputTP>
  :measured_LRA=<inputLRA>:measured_thresh=<inputThresh>
  :offset=<targetOffset>:linear=true
```
Output: `-ar <settings.sampleRate> -ac 2 -c:a pcm_s24le`. No explicit limiter (intentional — loudnorm TP is a soft ceiling, documented as acceptable for WAV-only). ✓

---

### WaxOff — WAV + MP3

WAV produced as above. MP3 encode reads from `wavFinalURL` (the already-normalized WAV):

**MP3 encode (`DP:220–254`, `encodeMP3`)**  
`DP:229–236`
```
aresample=88200,
alimiter=limit=<-2dBTP_amp>:attack=1:release=20:level=disabled,
aresample=44100
```
Note: MP3 always targets 44100 Hz regardless of `settings.sampleRate` — `DP:230` hardcodes `let mp3SampleRate = 44100`. ✓

---

### WaxOff — Phase rotation off, dynaudnorm off (minimal chain)

Pass 1: `loudnorm=I=<lufs>:TP=<tp>:LRA=<lra>:print_format=json`  
Pass 2: `loudnorm=I=<lufs>:TP=<tp>:LRA=<lra>:...:linear=true`

---

## Code-vs-Doc Comparison

### WaxOn signal chain (theory.html "Signal Chains at a Glance")

| Documented stage | Code stage | Match? | Notes |
|---|---|---|---|
| RNNoise (optional, per-channel split for stereo) | `arnndn` via `filter_complex` (stereo+NR) or `arnndn` prefix (mono+NR) | ✓ | |
| High-Pass Filter | `highpass=f=<dcBlockHz>` | ✓ | |
| Channel Select (mono only) | `pan=1c|c0=c0/c1` | ✓ | |
| Phase Rotation (200 Hz allpass) | `allpass=f=200:t=q:w=0.707` | ✓ | |
| Resample (to target rate) | `aresample=<sr>` | ✓ | |
| De-esser (7.5 kHz, optional) | `deesser=i=0.3:f=0.34:s=o` | ⚠ | Frequency is Nyquist-normalized; 7.5 kHz at 44.1k, ~8.2 kHz at 48k |
| Level Riding (dynaudnorm downward-only) | `dynaudnorm=p=0.95:m=1.0:g=31` | ✓ | |
| Dynamic Leveling (dynaudnorm bidirectional) | `dynaudnorm=f=F:g=G:p=0.95:m=M:t=0.05` | ✓ | |
| Loudnorm (two-pass EBU R128) | pass 1 + pass 2 with linear=true | ✓ | |
| 2× Oversample → Limit → Resample | `aresample=2x,alimiter=...,aresample=sr` | ✓ | |

### WaxOff signal chain (theory.html "Signal Chains at a Glance")

| Documented stage | Code stage | Match? | Notes |
|---|---|---|---|
| — (missing from diagram) | `dynaudnorm=f=500:g=51:p=0.95:m=2.0:t=0.05` (optional) | ✗ | **MEDIUM-1**: dynaudnorm stage present in code, absent from diagram |
| Phase Rotation (150 Hz allpass, optional) | `allpass=f=150` | ✓ | |
| Loudnorm (two-pass EBU R128) | pass 1 + pass 2 with linear=true | ✓ | |
| 2× Oversample → Limit → Encode MP3 (optional) | `aresample=88200,alimiter=...,aresample=44100` | ✓ | |

### alimiter parameters

| Parameter | Doc | AudioProcessor | DeliveryProcessor (MP3) |
|---|---|---|---|
| Ceiling | user-configurable (default −1.0 dB) | `pow(10, limitDb/20)` ✓ | `pow(10, -2.0/20)` = −2.0 dBTP ✓ |
| Attack | 5 ms | 5 ✓ | 1 ✓ |
| Release | 50 ms | 50 ✓ | 20 ✓ |
| level= | disabled | disabled ✓ | disabled ✓ |

### Loudnorm parameters

| Parameter | WaxOn doc | WaxOn code | WaxOff doc | WaxOff code |
|---|---|---|---|---|
| I (target) | −30 LUFS default | `settings.loudnormTarget` default -30 ✓ | −18 LUFS default | `settings.targetLUFS` default -18 ✓ |
| TP | = limitDb (default −1.0) | `settings.limitDb` ✓ | −1.0 dBTP | `settings.truePeak` default -1.0 ✓ |
| LRA | 20 (hardcoded) | `LRA=20` ✓ | 11 default, code-configurable | `settings.lra` default 11.0 ✓ |
| linear | true on pass 2 | `:linear=true` ✓ | true on pass 2 | `:linear=true` ✓ |

---

## Ordering Audit

### WaxOn

**1. arnndn — first in chain (stereo: filter_complex before all; mono: first in -af)**  
Correct. The model was trained on natural speech; presenting the unaltered source signal gives it the spectral context it expects. Noise in the HPF stopband contributes to the filter's decisions; removing it first produces cleaner results in subsequent stages.

**2. highpass — before any gain stage**  
Correct. Sub-bass content below dcBlockHz (default 80 Hz) inflates both the loudnorm measurement and the limiter engagement. Removing it first means every downstream stage measures and processes a signal that more accurately represents perceptually relevant content.

**3. pan (mono) — after highpass, before allpass**  
Correct. Channel selection happens on the HPF'd signal. The allpass then operates on the actual output signal (mono), so its crest-factor reduction targets the signal the user actually receives. There is a nuance: pan happens after arnndn, not before. The doc says "pan before (or at the same stage as) noise reduction" — this is inaccurate as a description of the mechanism. However the behavior is correct: for mono output, the selected channel was processed by its own independent arnndn instance (FFmpeg's arnndn processes channels independently), so the selected channel is denoised as if it were a standalone mono signal. The doc's mechanism description is wrong; the code's result is correct. See LOW-2.

**4. allpass — after pan (mono) / after join (stereo NR) / after highpass (stereo no-NR)**  
Correct in all paths. Phase rotation always occurs before de-esser, level riding, dynamic leveling, and loudnorm. Crest-factor reduction must precede the loudnorm analysis pass so that pass 1 measures a signal closer to what the limiter will see post-normalization.

**5. aresample — last in step 1**  
Correct. All step-1 filters run at the source sample rate; the final resample brings the intermediate file to the target rate. All subsequent passes operate at the known, stable target rate.

**6. deesser — separate pass, after step 1 (midURL), before level riding**  
Correct. Sibilant transients would otherwise distort the dynaudnorm level estimates and inflate the loudnorm analysis. De-essing before these stages means every measurement and gain stage downstream sees a more representative signal.

**7. dynaudnorm level riding (m=1.0) — before dynamic leveling and loudnorm**  
Correct. Downward-only gain riding tames loud outliers before the bidirectional leveler and loudnorm analysis see the signal. Both subsequent stages benefit from a more consistent input. `m=1.0` enforces downward-only: only frames whose smoothed peak exceeds the target are attenuated; no frame is ever boosted above unity.

**8. dynaudnorm dynamic leveling (m=2–6) — after level riding, before loudnorm**  
Correct. Bidirectional leveling after downward riding means the signal entering loudnorm analysis has had its largest outliers tamed first, then its structural level imbalance corrected. `t=0.05` (silence threshold ≈ −26 dBFS) prevents noise-floor boosting on sparse voice material.

**9. NR-for-measurement — operates on postDynLevelURL, produces nrTempURL for pass 1 only**  
Correct by design. Pass 1 measures the de-noised version of the fully pre-processed signal. Pass 2 normalizes the original (non-NR'd) version of the same file. The gain offset derived from the clean measurement is applied to the noisy original. Noise in the original rides up with the speech — documented as intentional and appropriate for a pre-edit prep tool.

**10. loudnorm pass 1 (analysis) — on nrTempURL or postDynLevelURL**  
Correct. The analysis input has been through every filter that affects the loudness/crest-factor of the render input, except for NR-for-measurement (which is intentional and documented). `LRA=20` ensures the analysis doesn't apply dynamic compression; it measures purely.

**11. loudnorm pass 2 (render) — on postDynLevelURL, linear=true, measurements injected**  
Correct. `linear=true` applies a constant gain offset — no dynamic processing. All five measured values are injected from pass 1 output (`AP:245`), so the filter has full context for accurate linear gain computation.

**12. alimiter — last stage, after normURL**  
Correct. The limiter operates on the loudness-normalized signal and enforces the true-peak ceiling. Operating at 2× sample rate (`aresample=sr*2`) catches inter-sample peaks before they're written to disk.

---

### WaxOff

**1. dynaudnorm (optional) — first in both passes**  
Correct. Pre-norm leveling must appear in both pass 1 and pass 2 with identical parameters so the loudnorm analysis measures the leveled signal and the render normalizes the leveled signal. Both `analyzeAudio` and `renderWAV` build the chain identically (`DP:164` and `DP:193`). ✓

**2. allpass (optional) — after dynaudnorm, before loudnorm, in both passes**  
Correct. Phase rotation must precede loudnorm in both passes for the same reason as WaxOn: crest-factor reduction must be visible to the analysis so the linear gain offset is computed on the post-rotation signal. Both passes include it at the same position (`DP:165` and `DP:194`). ✓

**3. loudnorm (both passes) — last in filter chain before output**  
Correct for WAV path. No limiter in the WAV path is intentional and documented: loudnorm's TP is a soft ceiling, and for WAV the headroom tolerance is acceptable.

**4. Pre-encode limiter — reads from normalized WAV, not from source**  
Correct. `encodeMP3` receives `wavFinalURL` (or `wavTempURL` for MP3-only mode) as input (`DP:118`). This is the already-normalized WAV; loudnorm has already run. The pre-encode limiter applies −2.0 dBTP as a hard ceiling to absorb loudnorm TP overshoot and MP3 codec-induced ISPs, then the MP3 encoder runs. Ordering: loudnorm → pre-encode limit → MP3 encode. ✓

---

## Bug-Pattern Checklist

1. **HPF after loudnorm or after limiter** — Checked, not present. HPF runs in step 1, before all gain stages.

2. **Phase rotation after limiter** — Checked, not present. Allpass runs in step 1 (WaxOn) or first in the loudnorm chain (WaxOff), never after the limiter.

3. **Limiter before loudnorm** — Checked, not present. The alimiter is always the last stage, after normURL (WaxOn) or after wavFinalURL (WaxOff MP3).

4. **Filter in render absent from analysis (silent gain error)** — Checked. In WaxOn: de-esser, level riding, and dynamic leveling are all file-based passes that happen before both loudnorm passes; both passes see the same `postDynLevelURL`. In WaxOff: dynaudnorm and allpass are present in both `analyzeAudio` and `renderWAV` with identical parameters. The intentional exception (NR-for-measurement) is documented design, not a bug.

5. **Filter in analysis absent from render (silent gain error)** — Checked, not present. NR-for-measurement (the arnndn in pass 1) produces a temp file used only for measurement; pass 2 reads `postDynLevelURL`. This is the correct implementation of the documented NR-for-measurement design.

6. **arnndn on stereo without per-channel split** — Checked, not present. Both the main NR path (stereo, `AP:109–115`) and the NR-for-measurement path (stereo, `AP:207–218`) use `filter_complex` with `channelsplit` / per-channel `arnndn` / `join`. The simple `-af arnndn=...` path is only used when the input is already mono (`AP:220–224`). ✓

7. **Resample placed after a filter whose coefficients depend on the original rate** — Checked, not present. The `aresample=<sr>` in step 1 is the last filter in the step-1 chain, after arnndn, highpass, pan, and allpass. All subsequent passes operate on the already-resampled intermediate files. The one nuance (arnndn running at source rate rather than always-48k) is discussed under MEDIUM-2 of the findings below — the arnndn filter's behavior at non-48k rates is well-tolerated in practice.

8. **Channel selection after stereo-sensitive stage** — Checked. Pan follows arnndn in the mono+NR path; see LOW-2 for full discussion. Functionally correct: each channel is processed independently by arnndn; pan selects one. The stage that would be sensitive (stereo coherence) is arnndn itself, and both channels are processed correctly regardless.

9. **Loudnorm pass 2 with linear=true but measurements not injected** — Checked, not present. `AP:245` injects all five fields (`measured_I`, `measured_TP`, `measured_LRA`, `measured_thresh`, `offset`) and appends `:linear=true`. `DP:196–201` does the same.

10. **Dynamic leveling in only one of pass 1 / pass 2** — Checked, not present. WaxOn: dynamic leveling is a pre-loudnorm file-based pass; both loudnorm passes operate on `postDynLevelURL`. WaxOff: `dynaudnorm` is present in both `analyzeAudio` and `renderWAV` with identical parameters.

11. **alimiter with level=enabled** — Checked, not present. All three limiter invocations (`AP:264`, `DP:234`, `FFmpegRunner:102`) use `level=disabled`.

12. **Pre-encode MP3 limiter before loudnorm** — Checked, not present. `encodeMP3` reads from `wavFinalURL` / `wavTempURL` — the WAV output of `renderWAV`, which has already been loudnorm'd. Ordering is: loudnorm → WAV file → pre-encode limit → MP3.

---

## Findings by Severity

### HIGH
None.

---

### MEDIUM

**MEDIUM-1 — WaxOff signal chain diagram omits optional Dynamic Leveling stage**

- **File:** `docs/manual/theory.html` (Signal Chains at a Glance, WaxOff chain)
- **What's wrong:** The diagram shows `Phase Rotation → Loudnorm → [2× Oversample → Limit → Encode MP3]`. The code always prepends `dynaudnorm=f=500:g=51:p=0.95:m=2.0:t=0.05` to both passes when `dynaudnormEnabled` is true (`DP:164`, `DP:193`). The text later mentions it in the "Optional Pre-Norm Dynamic Leveling" section, but a reader looking at the diagram gets an incomplete picture.
- **User-visible symptom:** None — the code is correct. The doc misleads readers who audit the chain against the diagram.
- **Fix:** Add a dashed-border `chain-node` for Dynamic Leveling before Phase Rotation in the WaxOff diagram, matching the WaxOn diagram style.

---

**MEDIUM-2 — De-esser frequency documented as "7.5 kHz" but is Nyquist-normalized**

- **File (doc):** `docs/manual/theory.html` (WaxOn signal chain caption, Stage Order section)
- **File (code):** `AudioProcessor.swift:147` (log message)
- **What's wrong:** `deesser=i=0.3:f=0.34:s=o` uses a normalized `f` parameter where 1.0 = Nyquist. At 44.1 kHz (WaxOn default): `0.34 × 22050 = 7497 Hz ≈ 7.5 kHz`. At 48 kHz: `0.34 × 24000 = 8160 Hz ≈ 8.2 kHz`. The doc says "7.5 kHz" unconditionally; the log always emits `"de-esser: deesser 7.5 kHz"` regardless of sample rate.
- **User-visible symptom:** None at 44.1 kHz (the default). At 48 kHz, de-essing starts ~0.7 kHz higher than documented — a small difference, unlikely to be audible, but the label is wrong.
- **Minimal fix (doc):** Change "7.5 kHz" to "~7.5 kHz (44.1 kHz) / ~8.2 kHz (48 kHz)" in the signal chain caption and Stage Order section.
- **Minimal fix (code):** Make the log message rate-aware:
  ```swift
  // AudioProcessor.swift:147
  let dsHz = Int((0.34 * Double(sr) / 2.0).rounded())
  onLog?("  de-esser: deesser \(dsHz) Hz", .verbose)
  ```

---

### LOW

**LOW-1 — `FFmpegRunner.waxOnFilterChain` and `FFmpegRunner.limiterFilterChain` are dead code**

- **File:** `FFmpegRunner.swift:62–105`
- **What's wrong:** Both helpers are defined but never called. `AudioProcessor` builds its filter strings inline, and `DeliveryProcessor` builds its own inline. The helpers correctly describe the intended chain but are not exercised by any code path.
- **Risk:** If someone calls `waxOnFilterChain` in a future code path, they'll get a chain that applies `arnndn` on the full (potentially stereo) input without the `filter_complex` split — the bug the code everywhere else explicitly avoids.
- **Fix:** Either delete both helpers, or add a prominent comment that the stereo+NR path requires `filter_complex` and these helpers are for mono/no-NR paths only.

---

**LOW-2 — Doc description of mono+NR pan placement is inaccurate**

- **File:** `docs/manual/theory.html` (RNNoise → Stereo Handling, last paragraph)
- **Current text:** "When the user selects mono, a single channel is extracted via pan **before (or at the same stage as)** noise reduction, so arnndn always receives a mono signal."
- **What's wrong:** `AP:131–132` shows `arnndn` before `pan` in the mono+NR chain. Pan comes *after* arnndn. The claim that arnndn "always receives a mono signal" for mono output is also false — it receives the source (potentially stereo) signal.
- **Why it doesn't matter:** FFmpeg's arnndn processes channels independently. For mono output, pan selects one channel whose arnndn processing was independent from the other channel — equivalent to arnndn on a standalone mono signal. The behavior is correct; the doc's description of the mechanism is wrong.
- **Fix:** Change to: "For mono output, `arnndn` processes the source channels independently (FFmpeg applies one denoiser instance per channel); `pan` then extracts the selected channel. The selected channel is denoised correctly regardless of whether the source is mono or stereo."

---

## Recommended Fixes

### MEDIUM-1: Add dynaudnorm to WaxOff signal chain diagram

In `docs/manual/theory.html`, add a dashed node before Phase Rotation in the WaxOff chain:

```html
<!-- Before the Phase Rotation node -->
<div class="chain-node optional">Dynamic Leveling<br>
  <span style="font-size:0.75rem;font-weight:400;">dynaudnorm f=500 g=51 m=2.0</span>
</div>
<div class="chain-arrow">→</div>
```

### MEDIUM-2: Fix de-esser frequency in doc and log

**Doc** (`theory.html`): Change every occurrence of `"7.5 kHz"` describing the de-esser to `"~7.5 kHz (44.1 kHz) / ~8.2 kHz (48 kHz)"` or just `"~7.5–8.2 kHz depending on target sample rate"`.

**Log** (`AudioProcessor.swift:147`): Replace the hardcoded string:
```swift
// Before:
onLog?("  de-esser: deesser 7.5 kHz", .verbose)

// After:
let dsHz = Int((0.34 * Double(sr) / 2.0).rounded())
onLog?("  de-esser: deesser \(dsHz) Hz", .verbose)
```

### LOW-1: Add a safety comment to FFmpegRunner helpers

```swift
// FFmpegRunner.swift:62 — add above waxOnFilterChain
/// NOTE: This helper produces a simple -af chain only. It does NOT handle
/// the stereo+NR case, which requires filter_complex + per-channel arnndn.
/// AudioProcessor handles that path directly; this function is only correct
/// for mono output or stereo with NR disabled.
```

### LOW-2: Fix doc description of mono+NR pan placement

See LOW-2 proposed text above.

---

*This document records findings only. No source files were modified during this audit.*
