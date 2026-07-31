# Changelog

All notable changes to WaxOn/WaxOff are documented here. Every version below has a matching `v*` git tag. Not every version has a GitHub **release** page: `release.sh` keeps only the ten most recent, so older versions are reachable by tag but their release pages have been pruned.

## [2.5.0] — 2026-07-30

**Diagnostics**
- WaxOff and WaxOn now warn when `loudnorm` falls back to dynamic normalization. `linear=true` is a request FFmpeg may refuse; when it refuses, the file lands under its target with its loudness range compressed — which is exactly what linear mode exists to prevent. 2.4.0 documented that this can happen but gave no way to tell whether it happened to your file. The pass-1 measurements are now checked against FFmpeg's own condition before pass 2 runs, and the console names which one failed: loudness range above the target, or insufficient true-peak headroom. Detection only — no audio is changed
- WaxOn warns and badges when a source with more than two channels is downmixed to stereo. A 5.1 or 7.1 source under Channels = Stereo is folded to two channels by FFmpeg's default matrix; the mono path already announced the equivalent conversion, and the stereo path was silent. The file list now shows a `MULTI→STEREO` badge alongside the existing `MULTI→MONO` and `STEREO→MONO` badges

**Correctness**
- WaxOff MP3-only deliveries get a clean ID3 title. In MP3-only mode the encoder read the title from an internal temp filename, leaving a fragment like `episode-lev-18LUFS.1a2b3c4d` in the tag — which then travelled into the podcast feed and every player. The title now comes from the delivered filename in both output modes. Both mode was never affected

**Interface**
- WaxOff shows each file's processing stage on its own row. Delivery runs several files at once, and a single shared readout displayed whichever file reported last, attributed to none of them. Each row now reads its own stage — "Analyzing loudness…", "Normalizing…", "Encoding MP3…" — and clears when that file finishes
- WaxOff shows verification progress in the toolbar. Output verification runs after files are written, so rows read Complete while work continues; on hour-long files that gap is over a minute. The toolbar now reads "Verifying delivered files… N done" next to Cancel, and no longer leaves a stale "Encoding MP3…" on screen after the encode has finished

**Robustness**
- Corrected the WaxOn disk-space reservation. The pre-flight check reserved temp space for five intermediate files per concurrent job; only four have existed since 2.2.0 removed one. On a nearly-full disk it could block a batch that would have fit

**Documentation**
- The manual documents WaxOff metadata handling: source metadata is carried through, and the title tag is replaced with the delivered filename
- The build floor is stated in the README and `Vendor/README.md` — Xcode 26 or later (Swift 6.2+). A fresh clone opened with an older Xcode fails to compile, and nothing said so
- Corrected the bug-tracking and version-mapping claims, resolved a stats-timing claim that could not be supported from the source, and removed an unreferenced image and anchor

**Developer**
- CI runs green again. It had been red since 2026-07-09 and through two releases: the Xcode pin was 16.4, which ships Swift 6.1, while the code requires Swift 6.2 for `nonisolated deinit`. Pinned to Xcode 26.3 — the toolchain `release.sh` builds from — so CI now compiles against the same SDK that ships
- `release.sh` refuses to release from a commit CI has not proven green, with `--allow-red-ci` to override
- The build is warning-free, 188 → 0 across both targets. The test target did not set `SWIFT_DEFAULT_ACTOR_ISOLATION`, so every cross-target access reported an isolation warning that Swift 6 language mode would make an error
- `actions/checkout` bumped to v5, off the deprecated Node 20 runtime

**Structural**
- Restored twelve missing `v*` tags for 2.0.0 through 2.2.0, and added the `[2.1.0]` entry this file never carried
- Internal working files moved out of the published Pages root; `docs/` now holds only user-facing material
- Removed dead code: unreachable error cases, unused computed properties, unused imports, and an inert `sed` rule in `release.sh`

## [2.4.0] — 2026-07-23

**Bundled FFmpeg**
- Bundled FFmpeg replaced — output verified bit-identical at identical settings. The app now ships an audio-only build of FFmpeg 8.0 produced from a recipe committed to this repository (`scripts/build-ffmpeg.sh`) instead of a third-party GPL binary. Parity was checked over a 17-fixture corpus: every WaxOn and WaxOff output matched the previous binary byte for byte
- The DMG is ~25 MB, down from ~51 MB. The bundled `ffmpeg` and `ffprobe` binaries a developer fetches while building are ~44 MB combined, down from ~103 MB. Both shrank because the video and image encoders are gone, and nothing in WaxOn or WaxOff used them
- No GPL-licensed components remain: x264, x265 and libvidstab are not compiled in. FFmpeg core is LGPL-2.1-or-later, LAME (MP3 encoding) is LGPL-2.0-or-later, and the `arnndn` filter is BSD-2-Clause. Complete source directions are in `Vendor/README.md` and on the release pages
- Build reproducibility: the recipe compiles with `-ffp-contract=off`. Without it the compiler is free to fuse multiply-add operations, and inside the recursive filters that difference accumulates — output would depend on the toolchain rather than on the source
- The build refuses to ship a binary that links anything outside the system: `--disable-autodetect` plus a hard `otool -L` check. An earlier build silently picked up a Homebrew library and failed to launch on machines without it

**Documentation**
- Documentation audit across the manual, theory doc, in-app Help, and README — a full claim-by-claim pass against the implementation raised 31 findings. 26 documentation corrections ship here; 1 is held pending [#4](https://github.com/sevmorris/WaxOnWaxOff/issues/4) (documenting the current behavior would publish a claim the code doesn't honor); 4 are code defects rather than doc errors, filed as [#2](https://github.com/sevmorris/WaxOnWaxOff/issues/2), [#3](https://github.com/sevmorris/WaxOnWaxOff/issues/3), [#4](https://github.com/sevmorris/WaxOnWaxOff/issues/4) and [#11](https://github.com/sevmorris/WaxOnWaxOff/issues/11)
- Corrected the `linear=true` claim in fourteen places. The docs stated that WaxOn and WaxOff never apply dynamic normalization; in fact `linear=true` is a request FFmpeg may refuse, and when it does, the filter falls back to dynamic normalization silently. The theory doc now carries a dedicated explanation of when that happens and what it looks like
- Known gap, deliberately shipped: the app still gives no in-app signal when the fallback occurs. A file affected by it reads noticeably below its target LUFS in the stats panel with no explanation. Detection is tracked as [#11](https://github.com/sevmorris/WaxOnWaxOff/issues/11)

## [2.3.0] — 2026-07-09

**Performance**
- WaxOff delivery is substantially faster with identical output: a 60-minute "Both" run completes ~26% sooner, and deep batches finish up to 2.25× faster (delivery now scales to nearly all CPU cores instead of half)
- File rows complete the moment their outputs are written; the post-render verification readout runs in the background and its console lines trail in per file
- File analysis on load is ~20× faster (Accelerate/vDSP), so long files reach "ready" in seconds instead of minutes; the post-processing stats/waveform refresh shares a single decode and is similarly vectorized
- Delivered-WAV verification uses FFmpeg's ebur128 meter at full precision; MP3 verification deliberately stays on loudnorm, whose true-peak measurement proved more accurate on hot lossy audio (see dev/perf-2026-07/)

**Developer**
- Hidden WaxPerfLog flag (`defaults write io.github.sevmorris.WaxOnWaxOff WaxPerfLog -bool YES`) emits per-stage timings to the unified log (category "Perf") for future performance audits

## [2.2.4] — 2026-07-01

**Documentation**
- Documentation audit remediation across the manual, theory doc, and README — nine findings fixed: MP3 channel claim made conditional under mono delivery, Strength step count corrected to 9 positions, naming drift resolved (Aggressiveness → Strength, Phase Alignment → Phase Rotation, Output → Channels), missing ISP (est.) stat / LUFS (src) label / OUTPUT badge and file-list channel badges documented, helper-line overgeneralization corrected, output-directory fallback chain completed (~/Desktop last resort), phase-label conditionality clarified
- WaxOn presets table "Output" column renamed to "Channels" to match the UI label
- Screenshots restored (WaxOn + WaxOff) with current v2.2.x UI

## [2.2.3] — 2026-07-01

**Interface**
- Rotary knobs no longer show the square system focus ring when clicked — the ring is suppressed on the circular controls in both WaxOn and WaxOff; keyboard focusability and arrow-key nudging are unchanged

## [2.2.2] — 2026-07-01

**Presets**
- WaxOn's "Edit Prep EBU" preset replaced with "ATSC A/85" — retargeted from −23 to −24 LUFS to match the US broadcast/video dialog reference level (ATSC A/85). WaxOn's fixed −1.0 dBTP true-peak ceiling is unchanged and remains stricter than ATSC A/85's −2.0 dBTP requirement

## [2.2.1] — 2026-06-30

**Interface**
- Stereo waveform view draws the dB scale labels per channel — L and R each get their own 0 / −6 / −12 / −24 / −48 anchored to their own waveform, instead of a single full-height scale that left the R channel's 0 dBFS unlabeled. Mono is unchanged

## [2.2.0] — 2026-06-30

**Processing**
- WaxOn with Loudness Norm off now linearly peak-normalizes instead of brick-wall limiting: the true peak of the post-leveling signal is measured and a single attenuate-only gain brings it to the −1.0 dBTP ceiling (a transparent pass-through when the source is already under it). Source dynamics are preserved at ingest — limiting is no longer applied at the prep stage unless Loudness Norm is on, where the 2× oversampled limiter remains the inter-sample-peak backstop

**Diagnostics**
- WaxOff re-measures each rendered output (the WAV, and the MP3 when produced) after render and logs the delivered values — "delivered <name>: <I> LUFS · <TP> dBTP" at info level, raw measured loudness/true-peak at verbose. The WAV/MP3 render chains are unchanged; this is a verification-only pass

**Interface**
- Waveform dB axis switched to a fixed sparse tick set (0, −6, −12, −24, −48 dBFS); the previous 1-dB spacing crowded the top 6 dB and dropped labels inconsistently
- WaxOn multi-file phase-rotation hint escalated from a passive note to an active recommendation — with 2+ files queued and phase rotation on, it now suggests applying phase rotation at the mix bus rather than per-track for same-room recordings; the default (phase rotation on) is unchanged
- WaxOff gains a mono delivery option for mono sources — a Mono/Stereo channel toggle in the Output Format panel (mirroring WaxOn's) that delivers a true single-channel WAV/MP3 instead of the dual-mono-stereo upmix. Enabled only when every loaded source is mono; defaults to off (dual-mono stereo unchanged); never downmixes a stereo source
- FLOOR noise-floor warning styling is suppressed in WaxOff — the stats-panel value and the file-list badge still appear, but the warning/critical coloring no longer fires, since a finished delivery mix may legitimately carry continuous low-level content (music beds, room tone under a mix). WaxOn's −40/−50 dBFS thresholds are unchanged

**Robustness**
- Update checker distinguishes a GitHub API rate-limit response (403 with a rate-limit body) from a genuine connectivity failure, surfacing an accurate "rate limit reached" message instead of "check your internet connection"

**Structural**
- Brand-accent and metering warning/critical colors routed through named semantic tokens (`brandAccent`, `meterWarning`, `meterCritical`); ~20 call sites across the view layer repointed with no change to any rendered color
- WaxOn's Loudness-Norm-on path fuses the pass-2 linear normalize and the 2× oversampled limiter into a single ffmpeg filter chain, eliminating one intermediate WAV write/read — internal only, with no change to the rendered result (verified loudness/true-peak-equivalent to the prior two-process approach)
- `moveAtomically` cross-volume branch (copy → rename → source cleanup) now covered by a RAM-disk fixture test (`hdiutil` / `diskutil`), skipping cleanly where a RAM disk can't be created
- DeliveryProcessor Both-mode partial-failure path (WAV succeeds, MP3 encode fails) now covered by a test asserting the file lands in successes with a non-nil `mp3FailureMessage` and the WAV present at its output path

## [2.1.0] — 2026-06-11

**Correctness**
- WaxOff accepts mono sources — a mono input is upmixed to dual-mono as the first filter in both the analysis and normalization passes, ahead of phase rotation and loudnorm, so the output lands on the configured target. 2.0.9 rejected mono files outright to avoid the ~3 LU overshoot caused by upmixing after normalization; upmixing first removes the cause instead of the file
- Analyzer RLB high-pass numerator coefficients corrected — the stage-2 biquad normalized `b0/b1/b2` by `d2`, giving 1/d2 gain rather than unity, and integrated loudness read ~0.04–0.05 LU below reference in a sample-rate-dependent way. Per BS.1770-4 only the denominator is normalized
- FFmpeg stream selection pinned to `-map 0:a:0` on the three invocations that read the original input, matching the stream the probe measures. Without it FFmpeg selects the highest-channel-count stream, so a file with stereo `a:0` and 5.1 `a:1` was probed as 2-channel and processed as 6
- loudnorm pass-1 measurements clamped to their documented option ranges before pass 2 — a clipped or full-scale source can report `input_i` above 0 LUFS, which loudnorm rejects with an opaque error
- WaxOn ignores the Left/Right channel pick on mono input — `pan=1c|c0=c1` referenced a channel that does not exist on a 1-channel source and failed at filter-graph configuration with nothing pointing at the Channel toggle as the cause
- OGG, Opus and WMA removed from the accepted extensions — they pass the ffprobe stream check but AVFoundation cannot open them, leaving files permanently stuck in an analysis error with no path to processing

**Robustness**
- Cancelling a batch no longer reports a failure — FFmpeg installs its own SIGTERM handler and exits with code 255 and reason `.exit` rather than `.uncaughtSignal`, so the cancel branch was never reached and the job was recorded as an ffmpeg error. Crash detection on the non-cancelled path is unchanged
- Fixed a crash when a process was terminated before it finished launching — `terminate()` from the watchdog and from the cancel handler is now guarded on a launch flag set only after `run()` succeeds
- Probed durations are range-checked before conversion — a corrupt or crafted container header reporting a non-finite, negative, or astronomically large duration trapped on overflow, taking down the whole batch at start. Values outside a 30-day ceiling are discarded and the existing fallback applies
- Commas and semicolons escaped in filtergraph values — both are chain and option separators, so either character in a path or metadata value broke the graph syntax
- Disk-space pre-flight estimates decoded PCM size rather than container size — a 64 kbps MP3 is ~17× smaller than its decoded 24-bit PCM, so the check could under-report required space by an order of magnitude
- Analysis concurrency bounded when files are dropped — N files previously launched 3N unbounded tasks (ffprobe, decode, waveform), creating file-descriptor and thread pressure proportional to batch size
- Cross-volume output moves are atomic — copy to a same-directory temp, then rename
- Per-file status is set on completion, cancellation state is preserved, a partial Both-mode result is reported rather than discarded, and a cancel guard was added
- WaxOff fails closed when a file's analysis has not completed — a nil `fileInfo` now sets an error state directing the user to wait, instead of passing the file through to normalization

**Documentation**
- Theory of Operation synced with the implementation — mono handling, the FLOOR / High Pass toggle coupling, the ISP (est.) stat, and the RMS fold-down
- Manual, theory doc and in-app Help updated to describe mono upmixing, and the removed formats dropped from the supported-format lists
- theory.html hero paragraphs no longer capped at 600px while the rest of the page uses 960px

**Structural**
- Swift 6.2 concurrency warnings resolved in `OutputAllocator` and `FileQueueCoordinator`
- Removed a duplicate MP3-failure log line, a redundant `fileExists` guard, and three stale audit labels
- Corrected comments that overstated the startup temp purge (it covers only the running PID's subtree), the loudnorm JSON brace fallback, and the `=` stripping rationale in metadata values
- Tests added for loudnorm measurement clamping, `effectiveTimeoutSeconds` bounds, and the spawn-failure launch guard

## [2.0.9] — 2026-06-02

**Correctness**
- WaxOff rejects mono input files before processing — a mono→dual-mono upmix would inflate integrated loudness by ~3 LUFS and silently miss the target
- Dithering removed from all output paths — triangular HP dither was applied where no word-length reduction occurs; 24-bit PCM output requires no dithering (documented in theory.html §Dithering)
- ffmpeg crash on a single file no longer silently cancels every other in-flight batch job (SIGTERM from user cancel is now distinguished from SIGSEGV/SIGABRT/OOM kill)
- Temp directory is now PID-scoped — a second app instance can no longer destroy the first instance's in-flight files at launch

**Audio-correctness documentation**
- theory.html: limiter-after-loudnorm LUFS undershoot documented as deliberate trade-off for both WaxOn and WaxOff
- theory.html: Buzzsprout target updated to −16 LUFS (current recommendation, removing stale mono/stereo distinction)
- AudioAnalyzer: ISP estimation comment — 2× linear interpolation, up to ~1–2 dB below true peak for near-Nyquist content
- AudioProcessor: int24 intermediate file choice documented (quantization floor ~−144 dBFS, no dither needed)
- DeliveryProcessor: sample-rate consistency assumption documented — pass-1 and pass-2 must run at the same rate

**Robustness**
- Proportional ffmpeg timeouts: max(300 s, duration × 4) so long recordings don't time out under load
- Symlink loop protection and 8-level depth cap in folder expansion
- Sub-400 ms files return −144 LUFS (honest "no valid measurement" sentinel) instead of a biased partial-block estimate
- Desktop fallback confirmation when a batch of more than one file would land on ~/Desktop
- Channel count upper bound: channel counts above 64 are rejected with a clear error
- `WaxOffSettings` gains a custom `init(from decoder:)` — a new property in a future version won't invalidate existing user settings
- AudioStreamProbe ffprobe errors logged to verbose log (distinguishes process failure from genuine no-audio-stream result)
- FFmpegManager cleans up stale versioned binary directories from prior app releases (~50 MB each)

**Structural**
- `ProcessingConfig.maxConcurrentJobs` centralizes the concurrency formula (was duplicated in three places)
- `runBoundedConcurrent` helper extracts the addNext+drain task-group pattern shared by both processors
- `OutputAllocator` consolidates the output-path reservation and collision-avoidance logic
- Phase rotation multi-file hint shown inline in the WaxOn file queue
- `DiskSpaceChecker` multiplier constants documented with intermediate file counts
- `FFmpegFiltersTests`: four `metadataValue` tests added; backslash-preservation contract pinned
- `release.sh`: version bump commit deferred until after notarization; `trap cleanup EXIT` registered

## [2.0.8] — 2026-05-31

- Fix silent update checks skipping new releases for up to 24 hours after launch
- Ignore non-app GitHub releases (`ffmpeg-deps-*`) when resolving the latest version

## [2.0.7] — 2026-05-31

- Cancel in-flight processing when the app quits
- WaxOn prep WAVs preserve metadata (`-map_metadata 0`)
- Triangular HP dither on final 24-bit PCM exports
- ffprobe audio-stream validation before analysis
- Swift 6: `OutputDirectory` helpers marked `nonisolated`
- CI: macOS 15 + Xcode 16.4; protect `ffmpeg-deps-*` releases from pruning
- Expanded integration tests; `CHANGELOG.md` added

## [2.0.6] — 2026-05-30

- WaxOff re-delivery warning for files matching `-lev*LUFS` output naming
- WaxOn re-prep warning fixed to detect `44kwaxon` / `48kwaxon` filenames
- README: clarify RNNoise is analysis-only; document sandbox-off security model
- Fix Release build (concrete preset stores; Swift 6.2 optimizer crash)
- CI: macOS 15 + Xcode 16.4 for project format 77
- Restore and protect `ffmpeg-deps-8.0-arm64` release assets

## [2.0.5] — 2026-05-30

- Apple Silicon (arm64) only — marketing and build settings aligned with bundled FFmpeg
- Loudnorm: NR analysis temp written at output sample rate (44.1 / 48 kHz)
- Parallel WaxOff batch processing; output directory fallback chain
- BS.1770-correct stereo LUFS in analyzer; ISP (est.) labeling
- WaxOff metadata preservation (`-map_metadata 0`); output collision avoidance
- Preset management UI; rotary knob accessibility; GPL source pinning in Vendor docs
- CI workflow and FFmpeg integration tests

## [2.0.4] — 2026-05-30

- Maintenance and documentation alignment

## [2.0.3] — 2026-05-27

- Asset optimization; version bump

## [2.0.2] — 2026-05-27

- Batch processing hardening; externalized FFmpeg binaries; expanded tests

## [2.0.1] — 2026-05-27

- App icon update

## [2.0.0] — 2026-05-27

- v2 UI: rotary knobs, unified toggles, WaxOn/WaxOff mode split
