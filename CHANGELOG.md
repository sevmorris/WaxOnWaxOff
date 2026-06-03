# Changelog

All notable changes to WaxOn/WaxOff are documented here. Version numbers match GitHub releases (`v*` tags).

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
