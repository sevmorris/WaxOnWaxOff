# Changelog

All notable changes to WaxOn/WaxOff are documented here. Every version below has a matching `v*` git tag. Not every version has a GitHub **release** page: `release.sh` keeps only the ten most recent, so older versions are reachable by tag but their release pages have been pruned.

## [Unreleased]

**Interface**
- Managing the file list moved out of the toolbar and into a bar pinned under the list itself, which is where macOS puts this kind of control — the `+`/`−` strip beneath a table in System Settings, Mail's rule list, Xcode's scheme editor. The toolbar was mixing two unrelated things: Process, the mode switcher and the preset picker act on the whole document, while Remove, Clear and Metadata act on whichever row happens to be selected. The bar holds `+`, `−`, **Metadata** (WaxOff only) and **Clear All**; the toolbar keeps Process/Cancel, the mode switcher, the preset picker, the verification readout and the settings toggle. Every enablement rule is unchanged, including the ⌘⌥⌫ shortcut on Clear All, and WaxOn gets no Metadata button because podcast metadata is a WaxOff concept
- The `+` button is new. 2.7.0 put adding files on the menu bar, which closed the hole where a keyboard-only user could not load anything at all; this puts it where someone is already looking. The file list is the thing you are working with, and the empty state tells you to drag onto the window — so the affordance for filling it belongs against the list, not two levels into a menu whose other entries are about documents. `+` opens a standard open panel that takes exactly what a drop takes: several files at once, any of the eleven supported formats, and folders, which are expanded and filtered the same way a dropped folder is. It stays available while a batch is running, because dropping files mid-batch always was — refusing at the button what the drop still accepts would be the inconsistency, not the safeguard
- The list pane is resizable from 150 to 600 pt and four titled buttons do not fit at the narrow end, so the bar drops its titles and shows icons alone when the width demands it. That is decided by measurement rather than by a hard-coded breakpoint, which would have been a guess about font metrics that goes stale the first time any of them changes. Every button carries a real accessibility label rather than relying on its title or on its tooltip: a tooltip becomes VoiceOver's *hint*, which is spoken only if the user has left "Speak hints automatically" on, so an icon-only button described only by `.help()` is an unlabeled button for anyone who has turned that off
- WaxOff writes per-episode podcast metadata into the MP3s it delivers. A **Metadata** button — available when exactly one file is selected, and not while a batch is delivering, though it returns for the verification tail where the files are already on disk — opens a sheet for that file with four fields: Podcast Name, Episode Title, Artwork and Chapters, written as ID3v2.3 `TALB`, `TIT2`, `APIC` and `CHAP`/`CTOC`. Until now the only tag WaxOff set was the title, taken from the delivered filename; everything else an episode carries in the file had to be added afterwards by a second tool, on a file WaxOff had just finished writing. The metadata is per file rather than part of a preset or the Settings sidebar — none of it is a processing setting, and a preset that carried one episode's chapters into the next would be worse than having no preset. Leaving Episode Title empty keeps what WaxOff has always done and tags the output filename stem, so a file nobody tags delivers exactly as it did before
- Chapters have two editing surfaces: a table first, one row per chapter — change a time, retitle a chapter, remove a row, add a row — and below it a paste box taking `MM:SS Title` or `HH:MM:SS Title`, one per line. Show notes are where chapter marks come from and they arrive as text, so pasting is how a list usually starts; but a paste box on its own means retyping a whole line to fix one timestamp, and the list is what a returning episode comes back to. The two stay in sync in both directions. Times must increase, no chapter may sit at or past the end of the audio, and every chapter needs a title. An error names the line at fault and Save is unavailable while it shows, because saving there would commit the last chapters that parsed rather than the ones on screen
- Artwork takes a PNG or JPEG, dragged onto the artwork well or picked with `Choose…`, and the sheet reports the pixel size, noting an image that is not square or that falls outside Apple Podcasts' 1400–3000 px range. Those are notes, not refusals — the file still delivers. A dropped file that is not a single PNG or JPEG is refused with the reason shown next to the well, and the check reads the file's own header rather than its extension, so something renamed to `.png` is caught at the drop instead of failing the encode much later
- A tag badge appears on the row of any file carrying metadata, with a tooltip listing what it has. It stays visible after delivery, which is the moment a batch is most worth scanning to confirm every episode was tagged
- Metadata applies to MP3 output only, and the sheet says so when the output mode writes no MP3. Anything that cannot be written degrades rather than failing the delivery, with a console line recording it: artwork that is missing, unreadable or a directory is skipped, chapters starting past the end of the audio are dropped, and chapters are skipped altogether when the file's length cannot be determined or when the chapter file cannot be written to the temp directory. Losing a whole delivery over cover art is the wrong trade
- Episode descriptions are deliberately not written, and no field offers to — this is a limitation rather than an oversight. FFmpeg's MP3 muxer maps `description`, `comment` and `podcast_desc` alike to `TXXX` user-defined frames, and neither `TDES` nor `COMM` is reachable through its metadata interface; that was checked against the bundled binary rather than assumed. A description field would therefore embed the text in a frame most players ignore while appearing to have done the job, which is worse than not offering one. The RSS feed is what podcast apps read episode descriptions from, and it remains the authoritative source

- The chapter paste box is never rewritten while its text does not parse. Editing one line's time past the next line's makes the whole list out of order, which is the ordinary way to retype a chapter time — and while that error showed, touching any control in the table replaced the text with the last list that parsed. The typed time went, the error cleared, and the sheet looked as though the edit had worked; the delivered file kept the old time. The text now stays until you fix it or clear it, and the table is read-only while it is broken, so there is one thing to correct in the one place that can be wrong

**Documentation**
- The manual and the in-app Help document the metadata sheet: the procedure for tagging an episode, the four fields and the ID3 frame each one writes, the chapter format and its rules, the Apple Podcasts artwork sizes as guidance, what happens when part of the metadata cannot be written, and why there is no description field

## [2.11.1] — 2026-08-23

**Fixed**
- **WaxOff's console reported the wrong gain figure.** The delivery log's Δ line read loudnorm's `target_offset` — a residual correction that stays near zero however far the source sits from the target — so it printed nonsense like "Δ -0.0 dB applied  |  -23.1 LUFS → -16 LUFS" on a real 7.1 dB move. It now reports the gain the target implies, which is what WaxOn has always shown. The verbose `offset:` line still prints `target_offset`, where that is the right number.
- **The large-gain warning could never appear.** "Large gain change — verify the source level and output before delivery" is meant to flag a source more than 12 dB from target, but it tested the same near-zero residual, so no file could trip it. A badly mis-leveled recording now raises it as intended.

**Developer**
- **The bundled FFmpeg is now reproducible, and repinned.** `scripts/build-ffmpeg.sh` pinned its working directory and passed `-Wl,-no_uuid`, so two runs on the same toolchain produce byte-identical binaries and the checksums in `Vendor/ffmpeg-manifest.env` can be verified rather than taken on trust — previously the published recipe produced a binary that did not match its own published checksums. Repinned to `ffmpeg-deps-8.0-audio-arm64-r2`. No change to delivered audio: parity against the old binaries over the full corpus was 221 gates passed, 0 failed, with null residuals at `-inf` and every LUFS and true-peak delta 0.0000.

## [2.11.0] — 2026-08-20

**Fixed**
- **A row now shows every file its job wrote.** Split L/R renders two files, and WaxOff's Both format renders a WAV and an MP3, but a row could only hold one of them — so the right channel and the MP3 existed on disk and in the console with no representation in the list. Both are now first-class: when a job writes more than one file, small tags above the waveform (**L** / **R**, or **WAV** / **MP3**) switch the panel between them, each with its own waveform, stats and file info. Reveal in Finder selects every output rather than just the first, and the row's status line names them all. Outputs after the first are measured the first time you look at them, so a split render costs no extra analysis unless you use it.

**Interface**
- **A styled installer window.** The disk image now opens to a laid-out window with the app, an arrow, and the Applications folder, instead of a bare list of two icons.

**Developer**
- The ffmpeg process machinery — watchdog, capture, cancellation, and telling a crash from a cancel — is now a single file shared verbatim with the sibling app repos rather than a copy in each. That code's drift had already cost something: hardening that landed here never reached ClipHack, leaving two latent crashes there for months. `release.sh` now refuses to publish when a shared file has diverged from its siblings.
- The DMG tooling is likewise byte-identical across repos; everything that had made the copies differ was a comment or a default argument.

## [2.10.0] — 2026-08-20

**Features**
- **Split L/R — per-speaker files from a two-microphone recording.** Field recorders and two-input interfaces routinely put one speaker on the left channel and another on the right. That file is not a stereo image; it is two mono takes sharing a container. Channels gains a third mode that treats it that way: WaxOn runs the whole pipeline once per channel and writes two mono files, tagged `-L-` and `-R-`. Each channel is measured and gained **independently**, which is the point of the mode — two people rarely sit the same distance from their microphones, and a shared gain would carry that imbalance into the edit. Previously the only way to do this was to run the file twice with Source Channel flipped, which produced the same output name both times and silently overwrote the first result unless you renamed in between. Split L/R needs a two-channel source; a mono or multichannel file falls back to a single mono file and says so, and the file list flags both cases before the batch runs.

**Interface**
- **Larger text throughout the settings panels and control bars.** Section labels, values, stat readouts and help text were all set small enough to be hard to read at a normal viewing distance, in panels with room to spare. Every size grew, and they now live in one place rather than as magic numbers duplicated across six view files — which is how they had drifted apart.
- **The Channels caption explains only the mode you have selected**, rather than all of them at once. The control already names the options; the caption only has to say what the selected one does.
- **The Loudness Norm caption says what the control does for you** — "consistent levels across files" — matching its neighbours, instead of describing its internals.
- **A knob dims when its toggle is off.** The Strength knob rendered at full colour whenever Dynamic Leveling was off, so a slot in the middle of the control bar looked live while doing nothing. Its label and value already faded; the knob now does too.
- The Loudness Norm tooltip no longer describes a two-pass analysis that WaxOn stopped performing in 2.9.0.

## [2.9.0] — 2026-08-19

**Performance & Core Processing**
- **Edit Prep is about three times faster.** WaxOn ran FFmpeg's two-pass `loudnorm` to compute what its own settings had already reduced to a single constant gain — it asked for linear mode, which by definition applies one gain and nothing dynamic. WaxOn now measures integrated loudness once with `ebur128` and applies that gain directly. On a ten-minute source the Edit Prep run drops from 8.99 s to 2.80 s, with the analysis stage alone falling from 7.14 s to 1.59 s.
- **Loudness accuracy improved rather than degraded.** Across quiet, normal, hot, speech-like and transient-heavy sources rendered to −30 LUFS, the largest miss was 0.23 LU with the old two-pass path and 0.00 LU with the new one. `loudnorm` gives up loudness accuracy when it pulls gain back to respect its soft true-peak target; applying the full gain and letting the limiter handle peaks lands closer to target, and on transient material it produced a lower true peak as well.
- **Silence is handled explicitly.** Where `loudnorm` reported `-inf` for silent input, `ebur128` floors at exactly −70 LUFS — the ITU-R BS.1770 absolute gate. WaxOn treats that floor as "nothing to measure" and passes the audio through ungained, rather than boosting silence by 40 dB.

**Documentation**
- WaxOn's −1.0 ceiling is now described accurately. With Loudness Norm on it is a brick-wall limiter holding **sample** peaks at −1.0 dBFS, not a true-peak limiter — 2.8.0 removed the 2× oversampling that made it true-peak accurate. Measured on an fs/4 inter-sample-peak tone: in at +0.41 dBTP, out at −0.14 dBTP, because the limiter never engaged while sample peaks sat 3 dB below the threshold. With Loudness Norm off the route is genuinely true-peak: WaxOn measures true peak and applies one downward gain to −1.0 dBTP. The asymmetry is deliberate for an ingest stage, and WaxOff enforces the strict oversampled true-peak ceiling at delivery.
- The manual, the theory document and the in-app Help no longer describe WaxOn as running a two-pass `loudnorm`, and the manual's limiter description no longer walks through the 2× upsampling that 2.8.0 removed.
- Remaining RNNoise references are gone from the manual and the vendor notes, which still claimed WaxOn ran it during analysis and documented a bundled model file that no longer ships. The `arnndn` BSD-2-Clause attribution is deliberately kept: the filter is still compiled into the bundled FFmpeg binary, so the notice obligation outlives the app's use of it.

**Developer**
- The test suite builds and runs again. A cleanup in 2.8.0 removed the test bundle's product reference and the XCTest framework entry from the project file alongside the RNNoise wiring, leaving dangling references that made the whole suite unbuildable. The app target was unaffected, so 2.8.0 built, notarized and shipped without the breakage surfacing — `release.sh` does not run tests, and the red CI it produced was overridden.
- Two scalar reference DSP engines and the hidden `WaxPerfLog` instrumentation are out of the shipping app. The engines were roughly 330 lines of duplicated DSP compiled into the binary purely so tests could diff the vectorized versions against them; the instrumentation existed for performance audits, not for users.

## [2.8.0] — 2026-08-19

**Performance & Core Processing**
- **Concurrency Scaling:** WaxOn batches now scale up to `cores - 1` parallel jobs (matching WaxOff's delivery model). The previous half-the-cores cap artificially limited throughput on deep queues.
- **Edit Prep Path Speedup:** WaxOn's EBU R128 Loudness Normalization no longer uses an RNNoise pass for measurement. Raw audio is passed directly to the EBU R128 analysis, bypassing model loading and complex filter graphs for a significant speed boost.
- **Limiter Simplification:** WaxOn now uses a standard sample-rate peak limiter instead of a 2x oversampled limiter. Edit prep does not require delivery-grade true-peak compliance, and dropping the oversampling saves nearly 10 seconds per 10 minutes of audio.
- **Default Path Optimization:** WaxOn's default "loudnorm off" path now measures true peak using a lightweight `ebur128` pass rather than a heavy `loudnorm` analysis pass.

## [2.7.0] — 2026-08-10

**Interface**
- You can add files from the menu bar. File ▸ Add Files or Folder…, or ⌘O. Until now dragging was the only way to get audio into the app: there was no button, no menu item, and ⌘O did nothing — so a keyboard-only user could not load anything at all. The panel takes files or a folder, and a folder chosen here is scanned exactly as a folder dropped on the window is, because both go through the same code
- WaxOn explains when to use Stereo, at the control rather than in the manual. The Channels toggle offered Mono and Stereo as equal options and said nothing about which applies, so Stereo read as the more faithful choice and a single-voice recording landed in a two-channel file for no benefit. The reasoning was already correct in the manual, three screens away; two sentences of it now sit under the toggle
- WaxOn's two channel controls no longer differ by one letter. CHANNELS (Mono/Stereo) and CHANNEL (Left/Right) rendered directly above one another, with the second enabled only when the first is Mono. The second is now SOURCE CHANNEL, which is what it selects

**Fixed**
- The file list cannot be edited while a batch is delivering. Disabling the toolbar's Remove and Clear covered one route and left three — swipe-to-delete and the Delete key, in both modes — so pressing Delete mid-batch removed rows the delivery was still writing to. The guard now sits in the view models, where every route reaches it. Reordering is still allowed: it removes nothing, and the batch matches its rows by identity rather than position
- WaxOff shows why a file failed. It was handed the reason and displayed a fixed "see Console" string instead, so the row said less than it knew. WaxOn has always shown the reason
- Four error alerts no longer send you to a "Console tab" that does not exist. The console is a toggle at the top right of the waveform area, and the alerts now say so
- WaxOff lists the formats it accepts when it skips a file, as WaxOn does
- The caption under WaxOff's output picker described the Channels control two rows below it, which already carries that explanation itself
- The Save Preset sheet accepts Return
- Console text can be selected and copied — it is where every processing error now points
- Tooltips showing the full path on truncated filenames and output folders, present in WaxOn and missing in WaxOff, are in both

**Accessibility**
- The settings and console toggles in both modes have accessibility labels. They are icon-only buttons, and a tooltip is not read as a name
- The knob no longer claims to be a button. It is adjustable, and reported itself with a trait that says otherwise

**Documentation**
- The Homebrew install is documented in the README, the app page, and the manual. `brew install --cask sevmorris/tap/waxonwaxoff`
- The manual documents the WaxOff verification pass — what it is, why every row reads Complete while it runs, and what Stop verifying stops

**Developer**
- `release.sh` bumps the Homebrew cask when it publishes

## [2.6.1] — 2026-08-10

Fixes and documentation. No audio processing changed — nothing in the signal chain, the filter graphs, or the delivered files is different from 2.6.0.

**Fixed**
- WaxOff no longer starts a second delivery if you press Process twice while it switches batches. Starting a batch during the verification tail cancels the outstanding one and restarts once it has unwound, and in between the app looked idle: Process was enabled and nothing said otherwise. A second press there began a batch that the outstanding one's cleanup then orphaned — it kept rendering to disk with no progress shown, no working Cancel, and a further press able to start yet another batch over the same output paths. The toolbar now reads "Starting next batch…" during that gap and refuses the second press
- The toolbar no longer looks stuck after the first batch you ever process. Both modes waited for the completion notification before clearing their running state, and on a Mac that has not yet answered the notification permission prompt that wait does not end until you answer it. A finished delivery sat behind a system prompt that is easy not to connect to the app. Nothing waits for the notification now
- Clear and Remove are unavailable while a batch is delivering. Both stayed live mid-run, and a batch works from the file list as it stood when you pressed Process — so clearing it stopped nothing. Files kept landing on disk while the rows tracking them disappeared. Both stay available during verification, where the files are already written

**Documentation**
- The manual and in-app Help document the verification pass: what it is, why every row reads Complete while it runs, what Stop verifying stops, and that the next batch can start during it. 2.6.0 shipped the behaviour with nothing describing it
- `Vendor/README.md` no longer contradicts itself about the withdrawn FFmpeg binaries. A rule near the top said not to delete the `ffmpeg-deps-*` releases, on the grounds that older ones remain the corresponding artifact for older app versions — while a later section records that one was deliberately removed for the opposite reason. The rule now names the release it protects, and the withdrawn tag is marked as not to be restored
- "Why Two Passes?" is converted to Simplified Technical English. It was the one paragraph the 2.5.1 conversion missed

**Developer**
- The WaxOff toolbar no longer works out its own state. It walked the same flags the view model already tracked, so "Process appears exactly when a batch can start" held only because two pieces of code happened to agree — and it had already drifted, with `canStartNewBatch` reading true during a restart while `process()` refused. A named state decides now, and tests pin the correspondence
- CI lints the shell scripts. `shellcheck` runs over `scripts/*.sh` at full strictness, and `release.sh` gets `zsh -n` — `shellcheck` cannot parse it at all, so the script that publishes releases, deletes GitHub resources and rewrites docs was the one file nothing checked
- CI runs on pull requests whatever their base branch. A PR based on anything but `main` triggered no workflow, so a stacked PR could reach ready-for-review having never been built
- `dev/deferred.md` no longer lists four issues as open that had all been closed

## [2.6.0] — 2026-08-10

**Interface**
- WaxOff shows a distinct state while it verifies delivered files. Verification runs after every row already reads Complete, and the toolbar used to keep showing a red Cancel for the whole of it — offering to abort work that was already written to disk. There is now a "Verifying delivered files… N done" readout with a Cancel scoped to what it actually stops: the remaining verification passes, not the delivery
- You can start a new WaxOff batch while the previous one is still verifying. Verification is advisory re-measurement of files already on disk, so there is no reason to wait it out — on a batch of hour-long files that was over a minute of nothing to do. Process is now available during that window and starting a batch ends the outstanding verification. It stays unavailable while a batch is genuinely still delivering, where a restart would abandon renders in progress

**Diagnostics**
- WaxOn reports which normalization `loudnorm` applied — linear or dynamic — in the Console at Verbose, matching what WaxOff gained in 2.5.0. WaxOn's wider `LRA=20` makes the dynamic fallback far less likely, but "less likely" is not "never", and the console now says which one your file got. Both modes also log when that outcome disagrees with what the pass-1 measurements predicted

**Licensing**
- The FFmpeg binaries bundled through v2.3.0 have been withdrawn from distribution. They came from a third-party static build made with `--enable-gpl`, and the exact Corresponding Source for it could not be obtained, so the GPL obligations attached to distributing it could not be met. The `ffmpeg-deps-8.0-arm64` binaries and the app DMGs for v2.2.1 through v2.3.0 have been removed. Copies already distributed keep the rights the GPL granted at the time; this ends further distribution, which is the part this project controls. Current builds are unaffected — they use the audio-only LGPL FFmpeg introduced in 2.4.0. See `Vendor/README.md`

**Documentation**
- The platform loudness targets in the Theory of Operation are corrected and sourced. Every figure now cites the platform's own documentation or the governing specification, and the undated "approximate as of early 2026" hedge is gone. Buzzsprout's target was listed as a single figure when it is two (−19 LUFS mono, −16 LUFS stereo); Apple's −16 LKFS is an authoring recommendation rather than playback normalization; Spotify's −14 LUFS is its music figure and it publishes none for podcasts; and YouTube publishes no loudness target at all, so the widely-quoted −14 LUFS is marked as unconfirmed rather than repeated. The AES citation now points at TD1008 (2021) instead of the superseded TD1004

**Developer**
- `release.sh` reverts the version bump on any failure, not only on a failed notarization. A dozen other exits — a build error, an expired certificate, a stapling failure one line below the branch that did revert — left the bump stranded in the working tree, which then blocked the next run on the dirty-tree preflight
- `release.sh` reverts the README, manual and landing-page rewrites the same way. They were rewritten in place twenty lines before being committed, and nothing restored them if anything in between failed
- Pruning old releases no longer deletes their git tags. It removed the release page, its assets and the tag, so a pruned version became unbuildable from a clean clone and unreachable from its own changelog entry — while `CHANGELOG.md` said older versions stay reachable by tag. The tag now survives; only the release page is pruned
- The duplicated desktop-fallback alert is factored into one definition shared by both modes

## [2.5.1] — 2026-07-31

Documentation and interface text only. No audio processing changed and no app behaviour changed — every edit in this release is text the app or the manual displays.

**Documentation**
- The manual (`docs/manual/index.html`) is rewritten in ASD-STE100 Simplified Technical English: short sentences, simple present, active voice, and one approved word for each meaning. Procedures, reference sections, and both processing pipelines are converted. Passages that explain *why* the app behaves as it does are deliberately kept as prose — Simplified Technical English states a mechanism well and carries an argument badly. The Theory of Operation (`docs/manual/theory.html`) is unchanged for the same reason
- Long reference entries that would have crowded a settings table now sit in a short subsection below it, and the table cell points to it

**Interface**
- The in-app Help is rewritten in Simplified Technical English, matching the manual
- Error messages and inline interface text are rewritten in Simplified Technical English. Two hedges are kept deliberately: the **Already Processed?** and **Already Delivered?** warnings still say a file *appears* to have been processed and that processing it again *may* degrade it, because that check reads filenames and can be wrong

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
