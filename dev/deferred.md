# Deferred items

Items identified during the 2.1.0 audit and fix cycle that are not
release-blocking but worth addressing in a future session.
Items from the 2026-07 perf cycle (`perf/waxoff-2026-07`) are tagged
[perf-2026-07]; its gate evidence is indexed in
[perf-2026-07/README.md](perf-2026-07/README.md).

## Bugs

Tracked as GitHub issues, not here. This file is for work deliberately
deferred, not for defects. Anything actionable belongs in the issue tracker.

No snapshot of which issues are open, deliberately. The one that used to sit
here listed #2, #3, #4 and #11 as open "as of 2026-07-25"; all four were closed
on 2026-07-31 and the list went on asserting otherwise until an audit caught
it. A copy of the tracker in a file that nobody updates is worse than no copy.
Read the tracker.

## Test gaps

- **Duration parse-site validation** — the parse-site guard (T2-5) is
  correct but untested; requires a crafted corrupt container. The
  `effectiveTimeoutSeconds` belt-and-suspenders is covered by the
  Session C tests.

## Technical debt

- **T3-9: Swift concurrency isolation** — the project builds with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in Swift 5 language mode.
  Several statics in FFmpegRunner, AudioAnalyzer, and WaveformGenerator
  are nominally main-actor but execute on GCD utility threads —
  tolerated in Swift 5, hard errors under Swift 6. Address before any
  language-mode bump.

- **T3-3: RMS fold-down** — stats-panel RMS is computed on the mono
  fold-down (L+R summed before squaring). Intentional and pinned by
  testStereoDualMonoRMSMatchesMono; documented in the ToO. Revisit if
  a per-channel RMS option is ever added.

- **[perf-2026-07] Oversample-chain resamplers (Bucket B, unapproved)**
  — the 2× oversample limiter chains (WAV render + MP3 pre-encode)
  still cost ~115 s/hour each; ~95% of that is the two 512-tap
  `aresample` hops, not the limiter. Any change alters delivered-audio
  bits and implicates the −1.0 dBTP guarantee — see the audit's
  Bucket B analysis and verification protocol before touching.

## Record only, no action

- **[perf-2026-07] Commit-narrative asymmetry** — `265ce4a` narrates
  removing the "verifying N output files" verbose marker; its addition
  in `9dfca8d` is visible only in that commit's diff. Cosmetic.
