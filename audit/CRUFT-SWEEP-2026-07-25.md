# Cruft & Loose-Ends Sweep — 2026-07-25

**Repo state at time of writing:** `main` @ `a691836` ("docs: update download link to v2.4.0"), working tree clean, in sync with `origin/main`.
**Scope:** cruft (leftovers no longer connected to anything) and loose ends (work started, tracked, or promised and never closed). Documentation *accuracy*, DSP correctness, prose, performance, and architecture were explicitly out of scope and were not evaluated.
**Read-only:** no tracked file was created, modified, or deleted; no branch created. Two verification builds were run into the scratchpad (`/private/tmp/.../scratchpad`), not into the repo.

---

## 1. Coverage summary

| Phase | What was searched, and how | Result |
|---|---|---|
| **1 — Repo surface** | `git ls-files` (124 tracked files), each basename grepped against every other tracked file for a reference; `git branch -a`/`git tag`/`git ls-remote --tags`/`gh release list`; `.gitignore` line by line; `git status --ignored`; `find` for `*.orig *.rej *.bak .DS_Store *.swp *~ *.tmp *.old`; `find -type d -empty`; blob-hash dedupe across the whole index; full-history blob-size scan via `git rev-list --objects --all \| git cat-file --batch-check`. `audit/` contents deliberately unread in this phase. | 6 findings. **No** stray editor/patch/backup artifacts anywhere in the tree. **No** large FFmpeg-era blob in history — the largest blob ever committed is 1.31 MB (`docs/images/waxoff-complete.png`); the binaries were never tracked. |
| **2 — Code** | Every declared type (67) reference-counted across app + tests; every `func` and every `var`/`let`/`case` declaration cross-checked for a second occurrence in the whole Swift corpus (Python AST-ish scan, not eyeballing); `TODO\|FIXME\|HACK\|XXX\|temporary\|for now\|placeholder\|not implemented` across app, tests, scripts, CI; all `UserDefaults`/`@AppStorage` keys enumerated; all `Bundle.main.url(forResource:)` lookups traced to on-disk resources; every error-enum case checked for a construction site; `XCTSkip`/disabled/empty tests; commented-out-code regex. | 5 findings. **Zero** `TODO`/`FIXME`/`HACK`/`XXX` markers exist in the entire codebase — nothing to date. **Zero** commented-out code blocks, **zero** `#if false` branches. All `XCTSkip` uses are legitimate environment gates (missing FFmpeg, no second volume, no RAM disk), not parked tests. |
| **3 — Build / release / CI** | `project.pbxproj` read for file references, targets, build phases, and the `PBXFileSystemSynchronizedBuildFileExceptionSet`; every script in `scripts/` and `docs/dev/perf-2026-07/` traced to an invoker; `fetch-ffmpeg.sh` ↔ `Vendor/ffmpeg-manifest.env` ↔ `Vendor/README.md` ↔ the pinned GitHub release reconciled four ways including on-disk SHA-256; `release.sh` read end to end against actual doc strings; `ci.yml` read and the last 15 CI runs pulled with `gh run list` + `--log-failed`; entitlements against the disabled-sandbox rationale; size claims measured against real bytes. | 4 findings, one of them the most serious in the sweep. Every script has a named invoker. Project↔disk parity is exact. |
| **4 — Docs & site (structural)** | All `href`/`src`/`<link>` in the three HTML files parsed and resolved against the on-disk tree and against the `id=` set of every page, in both directions; 16 external URLs probed with `curl`; every hardcoded version string located and matched against the `sed` rules in `release.sh`; each screenshot's last-modified commit compared against the last-modified commit of all 24 view/view-model files. | 3 findings. **Anchor integrity is clean** — all 34 distinct in-page anchors (45 occurrences) and all 5 cross-page anchors resolve, including the five the brief named. **Screenshots are current**: only two view commits post-date them (`4cee7af`, a tooltip string; `8d4f0ae`, `nonisolated deinit`), neither of which changes a rendered pixel. Size claims verified true. 15 of 16 external URLs return 200. |
| **5 — Reconciliation** | `audit/DOC-DRIFT-2026-07-22.md` read in full (678 lines, including §4 Open Questions and §5 Addendum); `docs/dev/deferred.md` (located under `docs/dev/`, not root) item by item against current code; `CHANGELOG.md` against `git tag`, `git ls-remote --tags`, and `gh release list`; `release-notes/`; `gh issue list` open (14) and closed (1); `gh api .../milestones?state=all`; every open issue re-verified against the code that would fix it. | 12 findings. This is where the loose ends are. |
| **6 — Report** | This file. | — |

**Verification builds run.** Two, both `** BUILD SUCCEEDED **`:
1. `main` as-is on the local toolchain (Xcode 26.3 / Swift 6.2.4) — proves the CI red is a toolchain pin, not a source defect.
2. A scratchpad copy of the tree with `import SwiftUI` removed from both view models — settles a `deferred.md` item that had been open pending exactly this check.

---

## 2. Findings

38 findings. Effort scale: **XS** < 5 min · **S** < 30 min · **M** 1–3 h · **L** > 3 h.

### CONTRADICTION — two tracked sources disagree

| ID | `path:line` | Evidence | Recommendation | Effort |
|---|---|---|---|---|
| **X-01** | GitHub issue [#1](https://github.com/sevmorris/WaxOnWaxOff/issues/1) vs [UpdateChecker.swift:41-54](WaxOnWaxOff/Services/UpdateChecker.swift) | Issue (opened 2026-06-11) reports the update checker showing "check your internet connection" on a 403 rate-limit. The code has handled this since 2.2.0: `responseError(statusCode:body:)` returns `.rateLimited` for 403/429 with a rate-limit body → *"GitHub's API rate limit was reached."* ([UpdateChecker.swift:126-138](WaxOnWaxOff/Services/UpdateChecker.swift)). Four tests pin it ([UpdateCheckerTests.swift](WaxOnWaxOffTests/UpdateCheckerTests.swift), all 4 methods). `CHANGELOG.md:67` records it shipped in 2.2.0 (2026-06-30). | **Close #1**, referencing the 2.2.0 entry. | XS |
| **X-02** | [Vendor/README.md:93](Vendor/README.md) vs the actual release pages | The file states: *"the GPL Corresponding Source directions for them are on the `ffmpeg-deps-8.0-arm64` and `v2.3.0` release pages."* `gh release view ffmpeg-deps-8.0-arm64` returns a 5-line body with no license or source text at all; `gh release view v2.3.0` returns the auto-generated commit list, also with none. Both pages still serve GPL-bearing artifacts (`ffmpeg`+`ffprobe`, and the DMG). By contrast `v2.4.0` and `ffmpeg-deps-8.0-audio-arm64` **do** carry full source sections — so the claim is true for the new pair and false for the old. This is the live half of issues [#5](https://github.com/sevmorris/WaxOnWaxOff/issues/5) / [#7](https://github.com/sevmorris/WaxOnWaxOff/issues/7). | Either add the directions to those two release bodies (making the sentence true), or reword `Vendor/README.md:93` to say the directions are pending under #5. Do not leave a compliance claim the artifacts don't back. | S |
| **X-03** | [docs/dev/deferred.md:9-11](docs/dev/deferred.md) vs the issue tracker | `deferred.md` §Bugs reads *"None currently tracked."* Five `bug`-labeled issues are open right now: [#1](https://github.com/sevmorris/WaxOnWaxOff/issues/1), [#2](https://github.com/sevmorris/WaxOnWaxOff/issues/2), [#3](https://github.com/sevmorris/WaxOnWaxOff/issues/3), [#4](https://github.com/sevmorris/WaxOnWaxOff/issues/4), [#11](https://github.com/sevmorris/WaxOnWaxOff/issues/11). | See **T-01** (single source of truth). At minimum, change the line to point at the tracker. | XS |
| **X-04** | [audit/DOC-DRIFT-2026-07-22.md:585](audit/DOC-DRIFT-2026-07-22.md) vs its own escalation rule | The triage marks F-M5 (disk-space pre-flight, undocumented) **OUT** — *"conditional — returns IN if F-CB2 slips past the next release."* F-CB2 (#3) did slip: `waxOnTempMultiplier = 5` and the `normURL` comment are both still present at [DiskSpaceChecker.swift:10-15](WaxOnWaxOff/Services/DiskSpaceChecker.swift) after 2.4.0 shipped. By the audit's own stated rule F-M5 is now IN, and nothing has been written or filed. | Decide: document the disk-space gate, or restate the condition. Either way, record the decision. | S |
| **X-05** | [CHANGELOG.md:3](CHANGELOG.md) vs `git tag` / `gh release list` | Header: *"Version numbers match GitHub releases (`v*` tags)."* CHANGELOG carries 18 versions (2.0.0 → 2.4.0). Only 6 of them still have a tag *and* a release (v2.2.1–v2.4.0). Twelve — 2.0.0 through 2.0.9 and 2.2.0 — were pruned by `release.sh`'s `KEEP_RELEASES` step and no longer resolve. Conversely tags `v1.0`/`v1.1` exist on origin with neither a release nor a CHANGELOG entry. | Hedge the header (e.g. *"…match the `v*` tags at time of release; older releases are pruned — see `release.sh`"*). | XS |

### UNFINISHED — started, tracked, or promised; never closed

| ID | `path:line` | Evidence | Recommendation | Effort |
|---|---|---|---|---|
| **U-01** | GitHub Actions, all runs since 2026-07-09 | **CI has been red on `main` for 16 days and through two releases.** `gh run list --workflow=ci.yml`: `failure` @ `a691836` (2026-07-24, the 2.4.0 cut), `failure` @ `2999791` (2026-07-09, the 2.3.0 cut), last `success` @ `65f2777` (2026-07-04). Failure log: `'isolated' deinit requires frontend flag -enable-experimental-feature IsolatedDeinit` ×6 → `Command SwiftCompile failed` → `** TEST FAILED **`. Cause: `nonisolated deinit {}` was introduced in `8d4f0ae` (2026-07-09) at [PresetStore.swift:69](WaxOnWaxOff/Models/PresetStore.swift) and [:142](WaxOnWaxOff/Models/PresetStore.swift) plus 8 other classes; `.github/workflows/ci.yml:20` pins `xcode-version: '16.4'` (Swift 6.1), where custom deinit isolation is still gated behind an experimental flag. **Verified not a source defect:** the same commit builds clean locally on Xcode 26.3 / Swift 6.2.4 (`** BUILD SUCCEEDED **`). The 2.4.0 release shipped with no green build behind it. | Raise the Xcode pin to a Swift 6.2 toolchain (26.x) and confirm the runner image offers it; `macos-15` may need to become `macos-26`. Highest-value item in this sweep. | S–M |
| **U-02** | [CHANGELOG.md:75-108](CHANGELOG.md) — the 2.0.9 → 2.2.0 gap | **v2.1.0 shipped and has no CHANGELOG entry.** `193a311` "Bump version to 2.1.0" and `7aa0416` "docs: update download link to v2.1.0" are `release.sh`'s own commit signature, so the release completed. An entry was written (`022b2c2`) then relabeled to `[Unreleased]` by `c6bdfe8` — *"these changes are unreleased, not part of the already-tagged v2.1.0"* — and that content was later cut as `[2.2.0]`. The relabel was correct; nobody then wrote the entry for what v2.1.0 *did* contain. `git log b573358..193a311` shows 26 commits (T2-x/T3-x audit fixes: RLB coefficient correction, atomic cross-volume move, filtergraph escaping, loudnorm clamping, mono upmix in WaxOff, extension-list correction…). | Write the `[2.1.0]` entry from that commit range. This is the exact class of loose end the brief predicted. | M |
| **U-03** | [audit/DOC-DRIFT-2026-07-22.md:604](audit/DOC-DRIFT-2026-07-22.md) | F-M9's doc clause was pulled from the doc branch pending #4, with the diff *"saved outside the tree"* and *"reapplies verbatim when F-CB3 lands."* There is no in-repo artifact: `git grep -i 'metadata\|ID3\|title tag'` across `docs/` returns one unrelated hit at `theory.html:1235`. If that external diff is lost, the work is lost, and nothing in the repo says it exists. | Attach the clause to issue #4 as a comment, or park it in `audit/`. A dependency that lives only on someone's disk isn't tracked. | XS |
| **U-04** | Milestones API | **Zero milestones exist** (`gh api repos/sevmorris/WaxOnWaxOff/milestones?state=all` → `[]`). All 14 open issues have `milestone: null`. The four defects the 2.4.0 notes queue for 2.5.0 — #2, #3, #4, #11 — are therefore not attached to anything; "queued for 2.5.0" lives only in prose at `CHANGELOG.md:15` and in the v2.4.0 release body.<br><br>*2026-07-25, post-scan: milestone 1 ("2.5.0") created 19:04:48Z. Attachment claim unchanged — open_issues 0, no issue references it.* | Create a `2.5.0` milestone and attach #2, #3, #4, #11 (and decide on #9/#10). | XS |
| **U-05** | [docs/dev/deferred.md:31-34](docs/dev/deferred.md) | *"Candidate for retiring in favour of `run()` in the tests once Both-mode partial-failure test is written."* That test was written and shipped in 2.2.0 — `testBothModePartialFailureDeliversWAVAndReportsMP3Failure` at [DeliveryProcessorIntegrationTests.swift:200](WaxOnWaxOffTests/DeliveryProcessorIntegrationTests.swift). The trigger has fired; the retirement never happened. [DeliveryProcessor.swift:179](WaxOnWaxOff/Services/DeliveryProcessor.swift) `func process(url:settings:onPhase:onLog:)` still exists, still discards `mp3FailureMessage` (`let (outputs, _, verifications) = …` at :191), and is still called only from tests (7 sites in `DeliveryProcessorIntegrationTests.swift`; no app call site). | Either retire the wrapper and move those 7 tests to `run()`, or delete the stale precondition from `deferred.md`. | M |
| **U-06** | [audit/DOC-DRIFT-2026-07-22.md:574](audit/DOC-DRIFT-2026-07-22.md) — Open Question 5 | OQ5 asked whether to hedge *"typically appear within a second or two"*. Never answered. Text is unchanged at [docs/manual/index.html:892](docs/manual/index.html). OQ1/2/3/4/6 all resolved (→ F-W6, the HelpView branch, the Vendor/README pass, withdrawn, and #2 respectively); OQ5 is the only one left dangling. | Answer it or strike it. | XS |
| **U-07** | [docs/dev/deferred.md:15-18](docs/dev/deferred.md) | "Duration parse-site validation" (T2-5) still untested — no test in `WaxOnWaxOffTests/` constructs a corrupt container or exercises the parse-site guard. Still accurately deferred. | Leave deferred; listed for completeness. | — |
| **U-08** | [docs/dev/deferred.md:20-27](docs/dev/deferred.md) | "[perf-2026-07] Mixed-outcome batch with the verification pool" still untested — the 12 tests in `DeliveryProcessorIntegrationTests.swift` cover Both-mode partial failure and cancellation, but none pins one file failing outright among successes in a batch. Still accurately deferred. | Leave deferred; listed for completeness. | — |
| **U-09** | [audit/DOC-DRIFT-2026-07-22.md](audit/DOC-DRIFT-2026-07-22.md) — F-M6, F-M13, F-M17 | Three MISSING findings triaged **OUT** and never converted to an issue or a note. Verified still undocumented: `grep -i 'notification'` (F-M6), `'no audio stream\|misnamed'` (F-M13), `'Send Feedback\|Report an Issue\|Support WaxOn'` (F-M17) return **zero** hits across `docs/manual/index.html`, `theory.html`, and `HelpView.swift`. These are deliberate omissions, but they exist only inside a 678-line audit file. | Record them somewhere durable (`deferred.md` §Docs, or a single "documented-out" issue) so the next sweep doesn't re-derive them. | XS |

### STALE — still referenced, but points at something moved, renamed, or gone

| ID | `path:line` | Evidence | Recommendation | Effort |
|---|---|---|---|---|
| **S-01** | [.github/workflows/ci.yml:15](.github/workflows/ci.yml) | `actions/checkout@v4` targets Node 20. Every run now emits: *"Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on Node.js 24: actions/checkout@v4."* | Bump to `actions/checkout@v5` while fixing U-01. | XS |
| **S-02** | [WaxOnWaxOff/Services/FFmpegManager.swift:56](WaxOnWaxOff/Services/FFmpegManager.swift) | `// Each is ~50 MB; cleaning them up avoids unbounded accumulation across updates.` Actual pinned binaries: `ffmpeg` 21,902,280 B and `ffprobe` 21,727,624 B (`ls -l`, SHA-256 confirmed against `Vendor/ffmpeg-manifest.env:9-10`). Tracked as [#15](https://github.com/sevmorris/WaxOnWaxOff/issues/15) — **confirmed still real**. | Fix with the 2.5.0 batch. | XS |
| **S-03** | [WaxOnWaxOff/Services/DiskSpaceChecker.swift:10-15](WaxOnWaxOff/Services/DiskSpaceChecker.swift) | Comment still enumerates `(4) normURL — optional loudnorm output` and `waxOnTempMultiplier = 5`; that intermediate was eliminated in 2.2.0 (`CHANGELOG.md:71`). Tracked as [#3](https://github.com/sevmorris/WaxOnWaxOff/issues/3) — **confirmed still real**. See also X-04. | Fix with the 2.5.0 batch. | XS |
| **S-04** | [WaxOnWaxOff/Views/WaxOnControlBar.swift:168](WaxOnWaxOff/Views/WaxOnControlBar.swift) | `private func aggressivenessLabel(_ amount: Double) -> String` — the control was renamed Aggressiveness → Strength in the 2.2.4 cycle (`CHANGELOG.md:33`) and the UI label at `:36` is `"STRENGTH"`. The function name is the last carrier of the retired term. (The *value* labels "Gentle"…"Aggressive" are a different axis and are correct — see **Do-not-touch**.) | Rename to `strengthLabel`. Cosmetic, zero risk (one call site, `:37`). | XS |
| **S-05** | [docs/dev/deferred.md:3](docs/dev/deferred.md) | *"Items identified during the 2.1.0 audit and fix cycle"* (also `:37`). There is no `[2.1.0]` section in `CHANGELOG.md` (see U-02), so this points at a cycle with no record. | Resolve alongside U-02. | XS |
| **S-06** | local tag set | `git tag` is missing `ffmpeg-deps-8.0-audio-arm64`, which exists on origin and is the tag currently pinned by `Vendor/ffmpeg-manifest.env:8`. Purely a local fetch gap, but it means a local `git tag` listing misrepresents which deps tag is load-bearing. Note that `ffmpeg-deps-8.0-audio-arm64` and `v2.3.0` point at the same commit (`2999791`). | `git fetch --tags`. Not a repo change. | XS |

### ORPHAN — nothing references it; deletion is your call

| ID | `path:line` | Evidence | Recommendation | Effort |
|---|---|---|---|---|
| **O-01** | `docs/images/waxon-console.png` | Referenced by nothing. Scope searched: every tracked file for the basename `waxon-console`; every `src=`/`href=` in all three HTML files; `README.md`. Zero hits. Last touched `4e6a5bf` (2026-05-27), two UI generations old, and it is **publicly served** — `https://sevmorris.github.io/WaxOnWaxOff/images/waxon-console.png` returns 200. | Delete, or wire it into the manual's `#interface` section. | XS |
| **O-02** | 4 local branches | `fix/doc-drift-2026-07` (`db19391`), `fix/helpview-drift-2026-07` (`7058ccf`), `perf/waxoff-2026-07` (`0eb6eca`), `rebuild/ffmpeg-audio-only-2026-07` (`4232f00`). `git branch --merged main` lists all four; `git rev-list --left-right --count main...<branch>` is `N 0` for each (main ahead, branch not ahead). `perf/waxoff-2026-07` also exists on origin. | Delete the three local-only ones; decide separately on the origin copy of `perf/waxoff-2026-07`. | XS |
| **O-03** | [docs/dev/](docs/dev/) — 10 files | Everything under `docs/dev/` publishes to the Pages site root: `dev/deferred.md`, `dev/perf-2026-07/README.md`, `.../meter_agreement.sh`, `.../a2-parity-baseline.json`, `.../capgate-final.txt` all return **200** from `sevmorris.github.io`. Pages config confirms `source: {branch: main, path: /docs}`. This is exactly [#6](https://github.com/sevmorris/WaxOnWaxOff/issues/6) — **confirmed real**. Internally the directory is well-kept: all 8 non-README files are indexed by `perf-2026-07/README.md`, no orphans. | Move `docs/dev/` out of the Pages path (e.g. to `dev/` at repo root, updating the two `docs/dev/perf-2026-07/` references in `CHANGELOG.md:25` and `DeliveryProcessor.swift:338`, and `meter_agreement.sh:6`'s `../../..` → `../..`). Then close #6. | S |
| **O-04** | [WaxOnWaxOff/Models/WaxOffSettings.swift:30-34](WaxOnWaxOff/Models/WaxOffSettings.swift) | The `lra == 11.0 → 9.0` migration in `load()`. **Now a permanent shim, not a migration.** LRA has no UI control anywhere (`git grep lra -- WaxOnWaxOff/Views/` → zero hits), all three built-in presets hardcode `lra: 9.0` ([Preset.swift:37,49,61](WaxOnWaxOff/Models/Preset.swift)), and the struct default is `9.0`. Nothing in the current app can ever write `11.0`, so the only source is a pre-2.x `UserDefaults` blob. It will run on every load forever. Pinned by `testLoadMigratesLegacyLRA` ([WaxOffSettingsTests.swift:13](WaxOnWaxOffTests/WaxOffSettingsTests.swift)). | Judgment call: keep indefinitely for the installed base, or set a removal version. If you keep it, add a line saying so — otherwise a future sweep flags it again. | XS |
| **O-05** | tags `v1.0`, `v1.1` | Present locally and on origin. No GitHub release (`gh release list` shows 8 releases; neither is among them), no CHANGELOG entry (CHANGELOG starts at 2.0.0). | Keep as historical markers or delete. Low stakes either way. | XS |
| **O-06** | [docs/manual/theory.html:725](docs/manual/theory.html) | `<h3 id="rnnoise-stereo">` — no `href="#rnnoise-stereo"` exists in any file. Independently rediscovered here; the prior audit saw it and dismissed it (`audit/DOC-DRIFT-2026-07-22.md:286`, *"harmless, not a finding"*). Reporting it so the disposition is recorded rather than re-derived a third time. | Leave it (deep-linkable heading), or add it to the theory TOC. | XS |
| **O-07** | `WaxOnWaxOff.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration` | Untracked empty directory. The project has no SPM dependencies (`PBXFrameworksBuildPhase` for the app target is empty; only `XCTest.framework` for the test target). Xcode leftover. | Delete from the working tree. Not a tracked change. | XS |

### DEAD — unreferenced by build, code, docs, scripts, or CI

Every entry below was established by scanning the **entire** Swift corpus (app + tests) for the identifier with word boundaries, plus a grep of all docs and scripts. Indirection cases were ruled out individually: none of these is reachable via `#selector`, KVO, an `@AppStorage` key, a `Bundle.main` string lookup, an Info.plist key, or an asset-catalog symbol.

| ID | `path:line` | Evidence | Recommendation | Effort |
|---|---|---|---|---|
| **D-01** | [WaxOnWaxOff/Models/WaxOffSettings.swift:51](WaxOnWaxOff/Models/WaxOffSettings.swift) | `var lraString: String` — exactly 1 occurrence repo-wide (its own declaration). Its two siblings `targetLUFSString` and `truePeakString` *are* used, at `WaxOffControlBar.swift:25` and `:12` — so the pattern is live and this member is the dead one. Not a `Codable` key (custom `init(from:)` at `:68-80` names only stored properties). | Delete. | XS |
| **D-02** | [WaxOnWaxOff/Models/WaxOffSettings.swift:55](WaxOnWaxOff/Models/WaxOffSettings.swift) | `var mp3BitrateString: String` — 1 occurrence repo-wide. Same reasoning as D-01. | Delete. | XS |
| **D-03** | [WaxOnWaxOff/Models/WaxOffSettings.swift:59](WaxOnWaxOff/Models/WaxOffSettings.swift) | `var sampleRateDisplay: String` — 1 occurrence repo-wide. Same reasoning as D-01. | Delete. | XS |
| **D-04** | [WaxOnWaxOff/Services/DeliveryProcessor.swift:651](WaxOnWaxOff/Services/DeliveryProcessor.swift) | `DeliveryError.analysisFailedNoMeasurements` — **never constructed.** Only two occurrences: the `case` declaration at `:651` and its `errorDescription` arm at `:658`. The other three cases each have a live `throw` (`:275`, `:446`, `:324`). The no-measurements path no longer throws — it logs *"⚠ Input is silent or near-silent — loudness normalization skipped."* at `:252` and continues. | Delete the case and its description arm. | XS |
| **D-05** | [WaxOnWaxOff/ViewModels/ContentViewModel.swift:5](WaxOnWaxOff/ViewModels/ContentViewModel.swift) | `import SwiftUI` — **compile-verified dead.** Grep finds no SwiftUI symbol in the file (`NSAlert` at `:134` is AppKit; `@Observable` is Observation; `Logger` is OSLog). Confirmed by building a scratchpad copy of the whole project with this import and D-06 removed: `** BUILD SUCCEEDED **`. This closes the `deferred.md:36-38` item that explicitly asked for a compile check. | Delete both imports together. | XS |
| **D-06** | [WaxOnWaxOff/ViewModels/DeliveryViewModel.swift:5](WaxOnWaxOff/ViewModels/DeliveryViewModel.swift) | Same as D-05; verified in the same build. | Delete. | XS |
| **D-07** | [release.sh:214](release.sh) | `sed -i '' "s\|\[Download v[0-9][0-9.]* (DMG)\]\|…"` targets a markdown link form that no longer exists — `README.md:9` uses an HTML anchor whose text is `Download Latest (DMG)`, with no version in it. The rule has matched nothing since the README switched to HTML. The three sibling rules at `:211-213` all still match live strings. | Delete the rule, or leave it as a harmless guard — but knowing it is inert. | XS |

---

## 3. Do-not-touch list (`INTENTIONAL`)

Checked, understood, deliberately not flagged. A future sweep should skip these.

**Code**
- **`generateScalarReference` / `analyzeScalarReference` and their accumulators** — [WaveformGenerator.swift:75](WaxOnWaxOff/Services/WaveformGenerator.swift) / [:235](WaxOnWaxOff/Services/WaveformGenerator.swift), [AudioAnalyzer.swift:176](WaxOnWaxOff/Services/AudioAnalyzer.swift) / [:303](WaxOnWaxOff/Services/AudioAnalyzer.swift). No production caller by design; they are the bit-exact references for `WaveformVDSPParityTests` and `AudioAnalyzerVDSPParityTests`, and the doc comments say so. They ship in the app target because the parity tests use `@testable import`.
- **`nonisolated deinit {}`** (10 classes, `8d4f0ae`) — deliberate opt-out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, documented inline at each site. It is what CI trips over (U-01); the fix is the CI pin, not the code.
- **`makeNSView` / `updateNSView`** — [RotaryKnobView.swift:153-154](WaxOnWaxOff/Views/RotaryKnobView.swift). `NSViewRepresentable` protocol requirements; zero call sites is correct.
- **`#Preview` blocks** — `ContentView.swift:242`, `ModePicker.swift:83`, `EmptyStateView.swift:29`. Self-referencing by construction, excluded from Release.
- **`aggressivenessLabel`'s return values** — `"Gentle" … "Aggressive"` at [WaxOnControlBar.swift:170-174](WaxOnWaxOff/Views/WaxOnControlBar.swift), and `"Aggressive +15.6 dB"` in the tooltip at `:42`. The 2.2.4 rename changed the *control name* (Aggressiveness → Strength), not the value scale. Both match the manual (`index.html:648`) and theory (`theory.html:876`). Only the *function name* is stale — that's **S-04**.
- **`WaxOnPreset.builtIn` partial initializers** — [WaxOnPreset.swift:38-46,51-59](WaxOnWaxOff/Models/WaxOnPreset.swift) omit four properties, which fall to struct defaults. The blank lines at `:42`/`:55` are visual grouping, not removed arguments.
- **All `XCTSkip` sites** — `IntegrationFFmpeg.swift:17` (no FFmpeg), `MoveAtomicallyTests.swift:33,35,63,68,76,82` (no second volume / no RAM disk), `AudioProcessorIntegrationTests.swift:126` (non-finite measurement). Environment gates, not parked tests.
- **`UserDefaults` key set** — `WaxOnSettings`, `WaxOffSettings`, `WaxOn/WaxOffUserPresets`, `WaxOn/WaxOffSelectedPresetID`, `lastMode`, `consoleVerbose`, `WaxPerfLog`. All read and written; no orphans from the 2.2.4 renames (those were Swift property renames inside a JSON blob, not separate defaults keys).
- **Entitlements** — [WaxOnWaxOff.entitlements](WaxOnWaxOff/WaxOnWaxOff.entitlements) declares exactly two keys, both used (`user-selected.read-write` for drops/panels; `network.client` for `UpdateChecker`), and the file explicitly documents what is *not* requested. Nothing to trim.

**Build / release**
- **`ffmpeg-deps-8.0-arm64`** tag and release — the superseded GPL build. Retained on purpose (`Vendor/ffmpeg-manifest.env:24-26`, `release.sh:288-301`, `Vendor/README.md:16`). Currently pinned tag is `ffmpeg-deps-8.0-audio-arm64`; both are load-bearing.
- **`release.sh` `KEEP_RELEASES=10`** — raised from 5 with a 13-line licensing rationale at `:288-301`.
- **`scripts/parity-check.sh`, `scripts/parity-corpus-gen.sh`** — invoked by hand; named as step 5 of `Vendor/README.md:56`. Not orphaned.
- **`docs/dev/perf-2026-07/meter_agreement.sh`** — invoked by hand; indexed at `perf-2026-07/README.md:16`. Its `../../..` ffmpeg resolution is correct for its current location (see O-03 if it moves).
- **`/parity-corpus/` in `.gitignore:20-21`** — self-documented as a backstop for a corpus that lives outside the tree.
- **`INFOPLIST_KEY_NSHumanReadableCopyright = "© 2026 Seven Morris\nLicensed under GPL-3.0"`** — correct. The app is GPL-3.0 by choice (`LICENSE`, 674 lines of GPLv3); the LGPL rebuild changed the *bundled binaries'* license, not the app's.
- **Duplicate icon PNGs** — `icon_128x128@2x` ≡ `icon_256x256`, `icon_16x16@2x` ≡ `icon_32x32`, `icon_256x256@2x` ≡ `icon_512x512`. Standard `@2x`/`@1x` sharing in an `.appiconset`.
- **`rnnoise` resource wiring** — `Bundle.main.url(forResource: "rnnoise", withExtension: nil)` at [AudioProcessor.swift:229](WaxOnWaxOff/Services/AudioProcessor.swift), file present (299,693 B, header `rnnoise-nu model file version 1`), and pulled into the app target via `PBXFileSystemSynchronizedBuildFileExceptionSet` (`project.pbxproj:31-39`). Exactly the string-lookup case the brief warned about — correct as wired.
- **`KnobFace` asset** — `Image("KnobFace")` at [RotaryKnobView.swift:89](WaxOnWaxOff/Views/RotaryKnobView.swift).

**Verified-current figures and structure**
- **`~44 MB` combined** (`README.md:84`, `Vendor/README.md:5`) — actual 21,902,280 + 21,727,624 = 43,629,904 B ≈ 43.6 MB. Both on-disk SHA-256s match `Vendor/ffmpeg-manifest.env:9-10` exactly, and match the two assets on `ffmpeg-deps-8.0-audio-arm64` byte for byte.
- **`~25 MB` DMG** (`CHANGELOG.md:9`, `release-notes/v2.4.0.md:9`) — the `v2.4.0` release asset `WaxOnWaxOff-v2.4.0.dmg` is 24,746,586 B ≈ 24.7 MB.
- **Screenshots are current.** `waxon-waveform.png` and `waxoff-complete.png` last changed in `9f2a390` (2026-07-01). Of all 24 view/view-model files, only two changed after that date: `4cee7af` (2026-07-22, a one-line tooltip string) and `8d4f0ae` (2026-07-09, `nonisolated deinit`). Neither alters anything rendered. `HelpView.swift` changed 2026-07-23 but is a separate sheet, not pictured.
- **Anchor integrity is clean, both directions.** All 34 distinct same-page anchors resolve (45 occurrences across the three pages); all 5 cross-page anchors resolve — `theory.html#phase-rotation`, `#dynamic-leveling`, `#nr-measurement` from the manual, and `index.html#waxon-settings`, `#waxon-output` from theory. No `href` anywhere points at a missing file.
- **Project ↔ disk parity is exact.** Both targets use `PBXFileSystemSynchronizedRootGroup`; the only `membershipException` is `rnnoise`. No `PBXFileReference` points at a missing file; no source file on disk is outside a target.
- **No pre-rebuild FFmpeg blob in history.** Largest blob ever committed: 1.31 MB. The binaries have always been gitignored release assets. No history rewrite is warranted.
- **Release-notes hygiene.** `release-notes/` holds exactly one file, `v2.4.0.md`, matching the only release cut since the curated-notes mechanism was added (`release.sh:254-264`). No orphans, nothing missing.
- **No `[Unreleased]` section** in `CHANGELOG.md`.
- **`theory.html` carries no version string — deliberate.** `release.sh:206-218` rewrites `README.md`, `docs/index.html`, and `docs/manual/index.html` only. `theory.html` is version-independent reference material; adding a version there would create a fifth hand-updated site. Leave as is.

---

## 4. Version-string inventory

Every hardcoded occurrence of the version, and who updates it.

| # | Location | Form | Updated by |
|---|---|---|---|
| 1 | `README.md:7` | `<strong>Version:</strong> 2.4.0` | **auto** — `release.sh:212` |
| 2 | `README.md:9` | `…/WaxOnWaxOff-v2.4.0.dmg` | **auto** — `release.sh:211` |
| 3 | `docs/index.html:439` | `…/WaxOnWaxOff-v2.4.0.dmg` | **auto** — `release.sh:217` |
| 4 | `docs/index.html:451` | URL + `>Download v2.4.0<` | **auto** — `release.sh:217,218` |
| 5 | `docs/manual/index.html:431` | `Manual — v2.4.0` | **auto** — `release.sh:208` |
| 6 | `docs/manual/index.html:466` | URL + `>Download v2.4.0<` | **auto** — `release.sh:206,207` |
| 7 | `project.pbxproj:397,432,458,482` | `MARKETING_VERSION = 2.4.0` (×4) | **auto** — `release.sh:90`, gated by the all-configurations agreement check at `:74-79` |
| 8 | `project.pbxproj:384,419,450,474` | `CURRENT_PROJECT_VERSION = 18` (×4) | **auto** — `release.sh:98` |
| 9 | **`CHANGELOG.md:5`** | `## [2.4.0] — 2026-07-23` | **HAND** — no automation, no gate |
| 10 | **`release-notes/v2.4.0.md`** | the filename itself | **HAND** — `release.sh:258` only *reads* `release-notes/${TAG}.md`; if you forget to write it, it falls back to generated notes silently ([#13](https://github.com/sevmorris/WaxOnWaxOff/issues/13)) |
| 11 | `docs/manual/theory.html` | *(none)* | n/a — deliberate, see Do-not-touch |

**Drift risks named:** #9 and #10 are the only hand-updated occurrences. #9 has no verification step at all — `release.sh`'s stale-reference gate at `:221-224` greps only `MANUAL_IDX`, `LANDING_IDX`, and `README.md`. Note also that the 2.4.0 CHANGELOG date (`2026-07-23`) precedes the tag (`2026-07-24T03:30Z`) by design: the entry is written before the cut. #10 is the mechanism issue #13 already tracks.

---

## 5. Unverifiable

| Item | Why it can't be settled from the repo |
|---|---|
| `https://ko-fi.com/sevmo` (`docs/index.html`, `docs/manual/*`, `README.md:92`) | Returns **403** to `curl` both with a default and a browser User-Agent. This is Cloudflare bot-blocking, not a dead link — the prior audit hit the same wall (`DOC-DRIFT-2026-07-22.md:286`). Settling it requires a real browser session. All 15 other external URLs return 200. |
| Issue [#7](https://github.com/sevmorris/WaxOnWaxOff/issues/7) — per-component GPL source for x264/x265/libvidstab | The prior audit established (`DOC-DRIFT-2026-07-22.md:653`) that the linked versions are **not recoverable from the binary** — the strings carry only format templates (`x264 - core 0000`, `HEVC encoder version %s`), and the third-party builder's original source manifest is no longer published. Nothing in this repository can close it; it needs an external artifact or a decision to unpublish. Out of this sweep's reach, correctly still open. |
| Whether `v1.0` / `v1.1` should be retained | No evidence in-repo either way (O-05). Your call on whether pre-2.0 history has value. |
| Whether `WaxOffSettings`' LRA shim still serves a live installed base | Depends on real-world install telemetry that doesn't exist here (O-04). Only you can decide the cutoff. |

---

## 6. Recommended disposition order

Sequenced so each step is verifiable before the next, and so nothing lands on a red build.

**Stage 0 — restore the safety net (do this before touching any code)**
1. **U-01** — raise the CI Xcode pin to a Swift 6.2 toolchain; **S-01** — `actions/checkout@v5` in the same commit. Get CI green on `main` first. Every step below is otherwise unverified by anything but a local build.

**Stage 1 — tracker truth (no code risk, unblocks planning)**
2. **X-01** — close #1 as fixed in 2.2.0.
3. **U-04** — create the `2.5.0` milestone; attach #2, #3, #4, #11.
4. **U-03** — move the F-M9 clause into the repo (issue #4 comment or `audit/`).
5. **X-03**, **U-09**, **U-06** — reconcile `deferred.md`'s Bugs section, record the documented-out findings, answer or strike OQ5.
6. **T-01 (see below)** — pick a single source of truth and write it down.

**Stage 2 — pure deletions (mechanically safe, CI now green to prove it)**
7. **D-05 + D-06** together (already compile-verified), then **D-01 – D-04**, then **D-07**. One commit; the build is the test.
8. **S-04** — rename `aggressivenessLabel` → `strengthLabel` (one call site).
9. **O-02** — delete the three merged local branches; decide on `origin/perf/waxoff-2026-07`.
10. **O-07** — remove the empty `swiftpm/configuration` directory.

**Stage 3 — the 2.5.0 code batch (now milestoned, now CI-verified)**
11. **S-02** (#15) and **S-03** (#3) — both one-line comment/constant fixes, both already filed.
12. #2, #4, #11 per the milestone.
13. **X-04** — F-M5's documentation, now that #3 is landing.
14. **U-05** — retire the `process(url:…)` wrapper and move its 7 tests to `run()`. Last, because it touches the most test surface.

**Stage 4 — docs and site (independent of everything above)**
15. **O-03** (#6) — move `docs/dev/` out of the Pages root. Three reference updates; do it as one commit and re-probe the four URLs afterward.
16. **O-01** — delete or wire up `waxon-console.png`. Fold into the same commit as O-03 if you're already in `docs/`.
17. **U-02 + S-05** — write the `[2.1.0]` CHANGELOG entry from `git log b573358..193a311`, then fix `deferred.md:3,37`.
18. **X-05** — hedge the CHANGELOG header.
19. **X-02** — add source directions to the `ffmpeg-deps-8.0-arm64` and `v2.3.0` release bodies, or reword `Vendor/README.md:93`. Closing this also closes the live half of #5.
20. **O-04**, **O-05**, **O-06** — judgment calls; decide and record, no rush.

**T-01 · Duplicate tracking — recommendation, not implemented.** Four surfaces currently carry status: GitHub issues (14 open), `docs/dev/deferred.md`, `audit/DOC-DRIFT-2026-07-22.md` §5, and `CHANGELOG.md` prose. They disagree in three places (X-01, X-03, X-04). **Recommend: GitHub issues become the single source of truth for anything actionable**, because it's the only surface with state, labels, and milestones, and it's already where the four 2.5.0 defects live. `deferred.md` then becomes a pure "considered and deliberately not doing" ledger with no bug tracking in it, and audit reports become immutable point-in-time records that *file* issues rather than *hold* status. That's a policy decision, so it is written here and not applied.

---

*Sweep complete. No tracked file was created, modified, or deleted; no branch was created; nothing was fixed. Awaiting an approved disposition list before any Phase 7 work.*
