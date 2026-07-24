# Changelog

All notable changes to WaxOn/WaxOff are documented here. Version numbers match GitHub releases (`v*` tags).

## [2.4.0] — 2026-07-23

**Bundled FFmpeg**
- Bundled FFmpeg replaced — output verified bit-identical at identical settings. The app now ships an audio-only build of FFmpeg 8.0 produced from a recipe committed to this repository (`scripts/build-ffmpeg.sh`) instead of a third-party GPL binary. Parity was checked over a 17-fixture corpus: every WaxOn and WaxOff output matched the previous binary byte for byte
- The binaries are ~44 MB combined, down from ~103 MB, because the video and image encoders are gone. Nothing in WaxOn or WaxOff used them
- No GPL-licensed components remain: x264, x265 and libvidstab are not compiled in. FFmpeg core is LGPL-2.1-or-later, LAME (MP3 encoding) is LGPL-2.0-or-later, and the `arnndn` filter is BSD-2-Clause. Complete source directions are in `Vendor/README.md` and on the release pages
- Build reproducibility: the recipe compiles with `-ffp-contract=off`. Without it the compiler is free to fuse multiply-add operations, and inside the recursive filters that difference accumulates — output would depend on the toolchain rather than on the source
- The build refuses to ship a binary that links anything outside the system: `--disable-autodetect` plus a hard `otool -L` check. An earlier build silently picked up a Homebrew library and failed to launch on machines without it

**Documentation**
- Documentation audit remediation across the manual, theory doc, in-app Help, and README — 31 findings from a full claim-by-claim pass against the implementation
- Corrected the `linear=true` claim in fourteen places. The docs stated that WaxOn and WaxOff never apply dynamic normalization; in fact `linear=true` is a request FFmpeg may refuse, and when it does, the filter falls back to dynamic normalization silently. The theory doc now carries a dedicated explanation of when that happens and what it looks like
- Known gap, deliberately shipped: the app still gives no in-app signal when the fallback occurs. A file affected by it reads noticeably below its target LUFS in the stats panel with no explanation. Detection is tracked as [#11](https://github.com/sevmorris/WaxOnWaxOff/issues/11)

## [2.3.0] — 2026-07-09

**Performance**
- WaxOff delivery is substantially faster with identical output: a 60-minute "Both" run completes ~26% sooner, and deep batches finish up to 2.25× faster (delivery now scales to nearly all CPU cores instead of half)
- File rows complete the moment their outputs are written; the post-render verification readout runs in the background and its console lines trail in per file
- File analysis on load is ~20× faster (Accelerate/vDSP), so long files reach "ready" in seconds instead of minutes; the post-processing stats/waveform refresh shares a single decode and is similarly vectorized
- Delivered-WAV verification uses FFmpeg's ebur128 meter at full precision; MP3 verification deliberately stays on loudnorm, whose true-peak measurement proved more accurate on hot lossy audio (see docs/dev/perf-2026-07/)

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
