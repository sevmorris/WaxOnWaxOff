# Deferred items

Items identified during the 2.1.0 audit and fix cycle that are not
release-blocking but worth addressing in a future session.
Items from the 2026-07 perf cycle (`perf/waxoff-2026-07`) are tagged
[perf-2026-07]; its gate evidence is indexed in
[perf-2026-07/README.md](perf-2026-07/README.md).

## Bugs

_None currently tracked._

## Test gaps

- **Duration parse-site validation** — the parse-site guard (T2-5) is
  correct but untested; requires a crafted corrupt container. The
  `effectiveTimeoutSeconds` belt-and-suspenders is covered by the
  Session C tests.

- **[perf-2026-07] Mixed-outcome batch with the verification pool** —
  no integration test pins one file failing outright (e.g., unreadable
  input) among successes in a WaxOff batch. Expected under the pool
  design in `DeliveryProcessor.run`: the failed file contributes no
  verifications, the successful files' "delivered" lines still all
  arrive before `run()` returns, and the successes/failures split is
  correct. Currently exercised only implicitly; the all-success and
  cancellation paths are pinned by `DeliveryProcessorIntegrationTests`.

## Code hygiene

- **`process(url:settings:onPhase:onLog:)` wrapper in
  DeliveryProcessor** — only called by integration tests; silently
  discards `mp3FailureMessage`. Candidate for retiring in favour of
  `run()` in the tests once Both-mode partial-failure test is written.

- **`import SwiftUI` in ContentViewModel and DeliveryViewModel** —
  pre-dates the 2.1.0 cycle; may be unused (verify with a compile
  check before removing).

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

- **[perf-2026-07] Commit-narrative asymmetry** — `ead64e2` narrates
  removing the "verifying N output files" verbose marker; its addition
  in `2d6b4eb` is visible only in that commit's diff. Cosmetic.
