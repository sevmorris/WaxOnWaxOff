# Changelog

All notable changes to WaxOn/WaxOff are documented here. Version numbers match GitHub releases (`v*` tags).

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
