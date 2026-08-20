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

## From the UI audit, 2026-08-10

A six-lens read of the view layer, findings adversarially verified. What was
worth fixing shipped in 2.7.0. These are the ones left, with the reason each
was left rather than done.

Two are defect-shaped and belong in the tracker if they are ever scheduled;
they sit here because nothing is scheduled and this file is the record of that.

- **ToggleSwitch exposes no role, value or keyboard reach** — nine instances:
  the four WaxOn switches via `WaxOnControlBar.switchCell`, and five more
  through `LabeledToggleSwitch` in both settings views. Sibling `Text` labels
  still give VoiceOver a name, so what is missing is state, role and
  activation, not the whole control. The pattern to copy is already in the
  repo at `RotaryKnobView.swift:43-57`. Mechanical, and these switches decide
  what WaxOn does to the audio.

- **WaxOff never reports a partial batch failure** — WaxOn does. Deliver ten
  files, have three fail, and WaxOff gives no batch-level signal; only the rows
  say so, and only since 2.7.0.

- **Process has no keyboard shortcut and no menu item** — deliberately left.
  2.7.0 added ⌘O for adding files, which was the harder gap because there was
  no path at all. A Process shortcut needs a key chosen rather than guessed;
  ⌘R is the obvious candidate.

- **A modal titled "Error" carries routine notices and partial successes** —
  needs a decision about what belongs in an alert versus inline, not a patch.

- **`LabeledToggleSwitch`'s left/right labels are plain tap targets** — no
  button role, no keyboard focus, selection conveyed only by font weight and a
  primary/secondary colour. Bigger than the `ToggleSwitch` item above because
  the fix changes the control's structure.

- **Eight findings were never adjudicated** — the verify phase hit the session
  limit twice. One of them, the `CHANNELS`/`CHANNEL` label collision, turned
  out to be real and shipped in 2.7.0 after a screenshot surfaced it; the
  earlier dismissal of it had compared definition-site line numbers rather
  than render order. Treat the remaining seven as unverified rather than
  false.

- **Splitting a stereo file into two mono files** — declined here, then
  **shipped in 2.10.0** as the Channels ▸ Split L/R mode. What changed the
  calculus: the decline assumed the DAW could do the same job, but it cannot do
  the part that matters — normalizing each speaker *independently*, so two
  people who sat at different distances from their microphones both arrive at a
  consistent level. The old workaround (run twice with Source Channel flipped)
  also silently overwrote its own first output, because `OutputAllocator` only
  de-duplicates within a batch.

  The model concern in this entry was right, and only half-addressed — see
  *One output per row* below.

- **Dynamic Leveling's position in the control bar** — considered, and
  addressed differently. It is default-off yet sits in the middle of the bar
  with a Strength knob beside it, which read as prime space for a rarely-used
  control. Moving it was rejected because the bar's left-to-right order matches
  the real signal chain (dynaudnorm does run before loudnorm), so reordering
  would make the bar imply a processing order the app does not use. The actual
  problem was visual weight: the knob rendered at full colour while disabled,
  and now dims with its label. If it still reads wrong, the remaining option is
  moving Dynamic Leveling and Strength into the Settings panel.

- **Panel type scale still has headroom.** Sizes grew in 2.10.0 (labels 9 → 11,
  values 11 → 13, stat readouts 12.5 → 14) and now live in one `AppFont` enum,
  so another step is a four-line change rather than twenty scattered edits.
  The settings panel still has empty space below OUTPUT DIR. The most cramped
  thing left is the control-bar captions, which wrap to three lines.

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

- **One output per row.** `JobResult` now carries `outputs: [URL]`, but
  `FileStatus.processed(outputURL:)` is still singular and the row still renders
  one waveform and one stats panel. So a Split L/R job writes two files and the
  row shows only the left one; both appear in the console and on disk, but the
  right channel has no representation in the list. `JobResult.output` is a
  computed `outputs[0]`, which is precisely the papering-over this file warned
  about when it declined the split — WaxOff does the same thing with
  `outputURLs.first`, dropping the MP3 from its row. Doing it properly means
  either two rows per split job, or a row that can carry and switch between
  several outputs. That would fix WaxOff's MP3 case at the same time.

- **[perf-2026-07] Oversample-chain resamplers (Bucket B, unapproved)**
  — the 2× oversample limiter chains (WAV render + MP3 pre-encode)
  still cost ~115 s/hour each; ~95% of that is the two 512-tap
  `aresample` hops, not the limiter. Any change alters delivered-audio
  bits and implicates the −1.0 dBTP guarantee — see the audit's
  Bucket B analysis and verification protocol before touching.

## Record only, no action

- **[perf-2026-07] `testFusedLoudnormLimiterEquivalentToTwoProcess` is orphaned.**
  It passes, but it asserts an equivalence about a fused loudnorm + 2×-oversampled
  limiter chain that WaxOn no longer has: 2.8.0 removed the oversampling and 2.9.0
  removed loudnorm from WaxOn entirely. The property still holds for WaxOff's WAV
  render, so the test is worth moving to the WaxOff suite or retiring deliberately
  — not deleting quietly just because it is green.

- **[perf-2026-07] Commit-narrative asymmetry** — `265ce4a` narrates
  removing the "verifying N output files" verbose marker; its addition
  in `9dfca8d` is visible only in that commit's diff. Cosmetic.
