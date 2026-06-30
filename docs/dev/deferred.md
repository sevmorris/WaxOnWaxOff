# Deferred items

Items identified during the 2.1.0 audit and fix cycle that are not
release-blocking but worth addressing in a future session.

## Bugs

_None currently tracked._

## Test gaps

- **Both-mode partial-failure** — no test for the WAV-success + MP3-
  failure path in DeliveryProcessor. Drive via `run()` with
  `outputMode = .both` and `mp3Bitrate = 0`; assert result lands in
  successes with non-nil `mp3FailureMessage` and WAV exists at output
  path.

- **Duration parse-site validation** — the parse-site guard (T2-5) is
  correct but untested; requires a crafted corrupt container. The
  `effectiveTimeoutSeconds` belt-and-suspenders is covered by the
  Session C tests.

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
