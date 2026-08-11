import XCTest
@testable import WaxOnWaxOff

/// End-to-end WaxOff tests — drive `DeliveryProcessor.run` against a
/// generated input, then re-measure the rendered output with loudnorm to
/// verify the configured target was actually reached. Requires the bundled
/// FFmpeg binaries (see `scripts/fetch-ffmpeg.sh`).
final class DeliveryProcessorIntegrationTests: XCTestCase {

    private var tools: FFmpegManager.Paths?
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tools = try IntegrationFFmpeg.locate()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxoff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    /// Rendered WAV should land within ±1 LU of the configured target. Catches
    /// regressions in the two-pass loudnorm wiring (analyze → render with
    /// measured values injected) and in the post-loudnorm limiter stage.
    func testWaxOffWAVHitsTargetLUFS() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_in.wav",
            durationSeconds: 6.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -23.0
        settings.truePeak = -1.0
        settings.outputMode = .wav
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")
        let job = try XCTUnwrap(result.successes.first)
        XCTAssertNil(job.mp3FailureMessage, "no MP3 sub-failure expected here")
        let outputs = job.outputURLs
        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))

        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: wav)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.0,
                       "WaxOff WAV output should sit within ±1 LU of the configured target")
    }

    /// "Both" output produces a WAV and an MP3 derived from it. Verifies both
    /// files exist and that the WAV side still hits target — the MP3 path
    /// re-runs the input through its own pre-encode limiter, so a regression
    /// there shouldn't poison the WAV measurement.
    func testWaxOffBothModeProducesWAVAndMP3() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_both.wav",
            durationSeconds: 4.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .both
        settings.mp3Bitrate = 160
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")
        let job = try XCTUnwrap(result.successes.first)
        XCTAssertNil(job.mp3FailureMessage, "no MP3 sub-failure expected here")
        let outputs = job.outputURLs
        XCTAssertEqual(outputs.count, 2)
        XCTAssertTrue(outputs.contains(where: { $0.pathExtension == "wav" }))
        XCTAssertTrue(outputs.contains(where: { $0.pathExtension == "mp3" }))

        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))
        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: wav)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.0)
    }

    func testWaxOffMP3HitsTargetLUFS() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_mp3_in.wav",
            durationSeconds: 6.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .mp3
        settings.mp3Bitrate = 160
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")
        let job = try XCTUnwrap(result.successes.first)
        XCTAssertNil(job.mp3FailureMessage, "no MP3 sub-failure expected here")
        let outputs = job.outputURLs
        let mp3 = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "mp3" }))

        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: mp3)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.5,
                       "MP3 encode may drift slightly from WAV; allow wider tolerance")
    }

    /// In MP3-only mode the encoder's input is the temp WAV, named
    /// `{outputStem}.{8-hex}.wav`. Deriving the ID3 title from that filename left
    /// the UUID fragment in the tag, which then ships to the podcast feed. The
    /// title must track the delivered stem, identically in both output modes.
    func testMP3OnlyTitleTagHasNoTempUUIDFragment() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_title_in.wav",
            durationSeconds: 4.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .mp3
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")
        let job = try XCTUnwrap(result.successes.first)
        XCTAssertNil(job.mp3FailureMessage, "no MP3 sub-failure expected here")
        let outputs = job.outputURLs
        let mp3 = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "mp3" }))

        let title = try await formatTag("title", ffprobe: tools.ffprobe, of: mp3)
        let expected = mp3.deletingPathExtension().lastPathComponent

        XCTAssertEqual(title, expected,
                       "MP3-only title must equal the delivered stem, not the temp source's name")
        XCTAssertFalse(title.contains("."),
                       "A '.' in the title means a temp UUID fragment survived: \(title)")
    }

    /// The post-render verification pass logs a "delivered … LUFS · … dBTP"
    /// info line for the WAV output (wav-only path).
    func testVerificationLogsDeliveredLineForWAV() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_verify_wav.wav",
            durationSeconds: 4.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .wav
        settings.outputDirectoryPath = workDir.path

        let (outputs, info) = try await runCapturingLog(input: input, settings: settings)
        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))
        let line = try XCTUnwrap(info.first(where: { $0.contains("delivered \(wav.lastPathComponent)") }),
                                 "expected a 'delivered' verification line for the WAV output")
        XCTAssertTrue(line.contains("LUFS") && line.contains("dBTP"),
                      "verification line should report integrated loudness and true peak")
    }

    /// Same verification line is logged for the MP3 output (mp3-only path).
    func testVerificationLogsDeliveredLineForMP3() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_verify_mp3.wav",
            durationSeconds: 4.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .mp3
        settings.mp3Bitrate = 160
        settings.outputDirectoryPath = workDir.path

        let (outputs, info) = try await runCapturingLog(input: input, settings: settings)
        let mp3 = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "mp3" }))
        let line = try XCTUnwrap(info.first(where: { $0.contains("delivered \(mp3.lastPathComponent)") }),
                                 "expected a 'delivered' verification line for the MP3 output")
        XCTAssertTrue(line.contains("LUFS") && line.contains("dBTP"),
                      "verification line should report integrated loudness and true peak")
    }

    /// In `.both` mode the verification pass runs once per delivered file, so
    /// both the WAV and the MP3 get their own "delivered" line.
    func testVerificationLogsDeliveredLinesForBothOutputs() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_verify_both.wav",
            durationSeconds: 4.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .both
        settings.mp3Bitrate = 160
        settings.outputDirectoryPath = workDir.path

        let (outputs, info) = try await runCapturingLog(input: input, settings: settings)
        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))
        let mp3 = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "mp3" }))
        XCTAssertTrue(info.contains(where: { $0.contains("delivered \(wav.lastPathComponent)") }),
                      "expected a 'delivered' line for the WAV in .both mode")
        XCTAssertTrue(info.contains(where: { $0.contains("delivered \(mp3.lastPathComponent)") }),
                      "expected a 'delivered' line for the MP3 in .both mode")
    }

    /// Both-mode partial failure: when the MP3 encode fails but the WAV already
    /// rendered, the file lands in `successes` with a non-nil `mp3FailureMessage`
    /// and the WAV exists at its output path; no MP3 is reported or written.
    ///
    /// The failure is forced with a negative `mp3Bitrate`, which reaches the
    /// spawned `libmp3lame` process and fails it at the ffmpeg layer (exit 222,
    /// "Result too large") — there is no Swift-side bitrate guard, so this
    /// exercises the genuine partial-failure aggregation path rather than a
    /// pre-flight short-circuit. (A bitrate of 0 is silently clamped to a valid
    /// default by libmp3lame and would NOT fail.) The `FFmpeg failed` assertion
    /// below pins that distinction.
    func testBothModePartialFailureDeliversWAVAndReportsMP3Failure() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "wax_off_partial.wav",
            durationSeconds: 2.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .both
        settings.mp3Bitrate = -1
        settings.outputDirectoryPath = workDir.path

        let collector = LogCollector()
        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings,
            onLog: { message, level in collector.append(message, level) }
        )

        XCTAssertEqual(result.failures.count, 0,
                       "WAV-success/MP3-failure must aggregate into successes, not failures")
        let job = try XCTUnwrap(result.successes.first)

        let mp3Failure = try XCTUnwrap(job.mp3FailureMessage,
                                       "partial failure must carry a non-nil mp3FailureMessage")
        // Proves the failure originated in the spawned ffmpeg encode process, not a
        // Swift-side guard that never runs ffmpeg.
        XCTAssertTrue(mp3Failure.contains("FFmpeg failed"),
                      "mp3FailureMessage should reflect a real ffmpeg encode failure, got: \(mp3Failure)")

        // WAV delivered and present on disk; MP3 neither listed nor written.
        let wav = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "wav" }),
                                "the WAV should be among the delivered outputs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path),
                      "the delivered WAV should exist at its output path")
        XCTAssertFalse(job.outputURLs.contains(where: { $0.pathExtension == "mp3" }),
                       "no MP3 should be reported among outputs when its encode failed")
        let expectedMP3 = wav.deletingPathExtension().appendingPathExtension("mp3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedMP3.path),
                       "no MP3 file should be written when its encode failed")

        XCTAssertTrue(collector.infoMessages.contains { $0.contains("MP3 encoding failed") },
                      "the processing log should record the MP3 encoding failure")
    }

    /// Pass 2 reports which normalization loudnorm actually applied, and that
    /// reaches the Console at Verbose. Guards the whole chain: the filter has
    /// to carry `print_format=json` (loudnorm defaults it to NONE, emitting
    /// nothing), the render has to capture stderr rather than discard it, and
    /// the block has to parse.
    ///
    /// The assertion is only that a type was reported and that it is one of
    /// loudnorm's two JSON spellings. It deliberately does NOT assert which
    /// one, and does not check the value against `predictsLinearMode` —
    /// prediction and actual are allowed to diverge, and pinning either would
    /// make this test a statement about the source material rather than about
    /// the plumbing.
    ///
    /// The fixture is 5 seconds, clear of the 3-second boundary at
    /// af_loudnorm.c:446 below which loudnorm forces linear mode from its
    /// short-first-frame path. The comparison there is strict (`<`), so 3.0
    /// would technically pass — but a test sitting on that edge would be
    /// pinning an implementation detail of FFmpeg's frame sizing.
    func testDeliveryLogsLoudnormNormalizationTypeAtVerbose() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "norm_type.wav",
            durationSeconds: 5.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .wav
        settings.outputDirectoryPath = workDir.path

        let collector = LogCollector()
        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings,
            onLog: { message, level in collector.append(message, level) }
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")

        let verbose = collector.verboseMessages
        let line = try XCTUnwrap(
            verbose.first(where: { $0.contains("applied") && $0.contains("normalization") }),
            "expected a Verbose line reporting the applied normalization type; got: \(verbose)")

        XCTAssertTrue(line.contains("linear") || line.contains("dynamic"),
                      "the reported type must be one of loudnorm's JSON spellings, got: \(line)")
        // The capitalised forms belong to print_format=summary. Seeing one here
        // would mean the wrong print format reached the filter.
        XCTAssertFalse(line.contains("Linear") || line.contains("Dynamic"),
                       "summary-format spelling in a JSON-format line: \(line)")

        // Verbose-only: it must not reach the default Console view. Matched on
        // the exact line rather than on the word "normalization", which also
        // appears in #11's .info fallback warnings ("loudnorm will apply
        // dynamic normalization…") — a sine source trips those via the
        // measured-LRA sentinel.
        XCTAssertFalse(collector.infoMessages.contains(line),
                       "the normalization-type line must not appear at .info")
    }

    // MARK: - Gain reporting

    /// The Delta line and the large-gain guard must both key off the gain the
    /// target implies (target - measured), not loudnorm's `target_offset`.
    ///
    /// Regression: WaxOff used `target_offset` for both. It is a residual
    /// correction that stays near zero however far the source sits from the
    /// target, so the Delta line reported "-0.0 dB applied" beside multi-dB
    /// moves and the guard below could never fire at any source level. This
    /// source measures about -35 LUFS against an -18 target -- a ~17 dB move,
    /// while its `target_offset` is about -0.05 dB.
    func testLargeGainChangeIsReportedFromTheGainNotTheLoudnormOffset() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "quiet_source.wav",
            durationSeconds: 6.0,
            sampleRate: 44100,
            amplitude: 0.22
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.outputMode = .wav
        settings.outputDirectoryPath = workDir.path

        let (_, info) = try await runCapturingLog(input: input, settings: settings)

        let warning = try XCTUnwrap(info.first(where: { $0.contains("Large gain change") }),
                                    "a ~17 dB move must trip the large-gain guard; got: \(info)")
        XCTAssertTrue(warning.contains("+1"),
                      "the guard must quote the gain, not the near-zero offset: \(warning)")

        let delta = try XCTUnwrap(info.first(where: { $0.contains("dB applied") }),
                                  "expected a Delta line; got: \(info)")
        XCTAssertTrue(delta.contains("+1"),
                      "Delta must report the gain the target implies, not target_offset: \(delta)")
        XCTAssertFalse(delta.contains("-0.0 dB applied"),
                       "Delta reported the loudnorm residual again: \(delta)")
    }

    // MARK: - Deferred verification (A1b, verification pool)

    /// Batch path: a file's completion callback fires at file-written and
    /// strictly precedes that file's own verification lines. Verification
    /// drains in an independent pool concurrent with delivery, so lines from
    /// one file may interleave with another file's delivery — global phase
    /// ordering is deliberately NOT asserted. All six "delivered" lines
    /// (3 WAV + 3 MP3) arrive before run() returns, correctly attributed.
    func testFileCompletionPrecedesItsOwnVerificationLines() async throws {
        let tools = try XCTUnwrap(tools)
        var jobs: [DeliveryJobInput] = []
        for i in 0..<3 {
            let input = try IntegrationFFmpeg.makeSineWAV(
                ffmpeg: tools.ffmpeg, directory: workDir, name: "defer_\(i).wav",
                durationSeconds: 3.0, sampleRate: 44100
            )
            jobs.append(DeliveryJobInput(id: UUID(), url: input))
        }
        let idToName = Dictionary(uniqueKeysWithValues: jobs.map {
            ($0.id, $0.url.deletingPathExtension().lastPathComponent)
        })

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .both
        settings.mp3Bitrate = 160
        settings.outputDirectoryPath = workDir.path

        let events = EventCollector()
        let result = try await DeliveryProcessor().run(
            inputs: jobs,
            settings: settings,
            onFileCompleted: { r in events.append("completed:\(idToName[r.id] ?? "?")") },
            onLog: { message, _ in
                if message.hasPrefix("  delivered ") { events.append("verify:\(message)") }
            }
        )

        XCTAssertEqual(result.failures.count, 0)
        XCTAssertEqual(result.successes.count, 3)

        let ordered = events.snapshot()
        let verifyLines = ordered.filter { $0.hasPrefix("verify:") }
        XCTAssertEqual(verifyLines.count, 6, "3 WAV + 3 MP3 delivered lines must all arrive before run() returns")

        for i in 0..<3 {
            let name = "defer_\(i)"
            XCTAssertEqual(verifyLines.filter { $0.contains("\(name)-lev-18LUFS.wav") }.count, 1)
            XCTAssertEqual(verifyLines.filter { $0.contains("\(name)-lev-18LUFS.mp3") }.count, 1)
            let completionIndex = try XCTUnwrap(ordered.firstIndex(of: "completed:\(name)"),
                                                "missing completion event for \(name)")
            let firstVerifyIndex = try XCTUnwrap(
                ordered.firstIndex { $0.hasPrefix("verify:") && $0.contains("\(name)-lev") },
                "missing verification lines for \(name)")
            XCTAssertLessThan(completionIndex, firstVerifyIndex,
                              "\(name): completion must precede its own verification lines")
        }
    }

    /// Cancelling at the moment of completion skips this file's deferred
    /// verifications cleanly: run() throws CancellationError and no
    /// "delivered" line is ever logged (no orphaned work in either pool).
    func testCancelAfterCompletionSkipsDeferredVerifications() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir, name: "defer_cancel.wav",
            durationSeconds: 3.0, sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .both
        settings.outputDirectoryPath = workDir.path

        let events = EventCollector()
        let taskBox = TaskBox()
        // The box is populated on the next statement after Task creation —
        // microseconds — while onFileCompleted fires only after several ffmpeg
        // invocations complete (hundreds of ms), so the read below is safe.
        let task = Task {
            try await DeliveryProcessor().run(
                inputs: [DeliveryJobInput(id: UUID(), url: input)],
                settings: settings,
                onFileCompleted: { _ in taskBox.cancel() },
                onLog: { message, _ in
                    if message.hasPrefix("  delivered ") { events.append(message) }
                }
            )
        }
        taskBox.set(task)

        do {
            _ = try await task.value
            XCTFail("expected CancellationError from cancel during the verification phase")
        } catch is CancellationError {
            // expected
        }
        XCTAssertTrue(events.snapshot().isEmpty,
                      "no deferred verification may run after cancellation")
    }

    /// Mixed-outcome batch: one input that fails outright, sat between two good
    /// ones. Pins three things the all-success and cancellation tests above do
    /// not reach. The failure aggregates into `failures` without tearing down
    /// its siblings — the delivery loop returns `.failure` rather than throwing,
    /// so only `CancellationError` propagates. Both successes still get their
    /// "delivered" line, all in before `run()` returns. And the failed file
    /// contributes none, because verifications are yielded to the pool on the
    /// success path only.
    ///
    /// The bad input is a `.wav` holding non-audio bytes, written with
    /// Foundation alone. Unreadable, not absent: it exists with a valid
    /// extension, so nothing short-circuits ahead of ffmpeg and the failure
    /// lands in the first ffmpeg stage. Same intent as the negative-bitrate
    /// fixture above — drive a real ffmpeg-layer failure, never a Swift-side
    /// pre-flight. (The disk-space and extension gates live in DeliveryViewModel
    /// and FileQueueCoordinator, upstream of the processor, so neither is on
    /// this path.)
    func testMixedOutcomeBatchSplitsResultsAndVerifiesOnlySuccesses() async throws {
        let tools = try XCTUnwrap(tools)

        var good: [DeliveryJobInput] = []
        for i in 0..<2 {
            let url = try IntegrationFFmpeg.makeSineWAV(
                ffmpeg: tools.ffmpeg, directory: workDir, name: "mixed_good_\(i).wav",
                durationSeconds: 3.0, sampleRate: 44100
            )
            good.append(DeliveryJobInput(id: UUID(), url: url))
        }

        let badURL = workDir.appendingPathComponent("mixed_bad.wav")
        try Data("not audio — a .wav extension over plain text".utf8).write(to: badURL)
        let bad = DeliveryJobInput(id: UUID(), url: badURL)

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .wav
        settings.outputDirectoryPath = workDir.path

        let collector = LogCollector()
        let result = try await DeliveryProcessor().run(
            inputs: [good[0], bad, good[1]],
            settings: settings,
            onLog: { message, level in collector.append(message, level) }
        )

        // The split is correct and correctly attributed.
        XCTAssertEqual(result.failures.count, 1, "the unreadable input must land in failures")
        XCTAssertEqual(result.successes.count, 2, "a sibling failure must not take down the good files")
        XCTAssertEqual(try XCTUnwrap(result.failures.first).id, bad.id,
                       "the failure must be attributed to the unreadable input")
        XCTAssertEqual(Set(result.successes.map(\.id)), Set(good.map(\.id)),
                       "both good files must be reported as successes")

        // One "delivered" line per success, all of them in by the time run()
        // returns — the drain is a sibling task-group child, so the group
        // cannot finish while a verification is outstanding.
        let info = collector.infoMessages
        let delivered = info.filter { $0.contains("delivered ") }
        XCTAssertEqual(delivered.count, 2,
                       "expected exactly one delivered line per success before run() returned, got: \(delivered)")
        for job in result.successes {
            let wav = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "wav" }))
            XCTAssertTrue(delivered.contains { $0.contains("delivered \(wav.lastPathComponent)") },
                          "missing delivered line for \(wav.lastPathComponent)")
        }

        // The failed file contributes nothing to the verification pool, and no
        // output of its own is written.
        let badStem = badURL.deletingPathExtension().lastPathComponent
        XCTAssertFalse(delivered.contains { $0.contains(badStem) },
                       "a failed file must yield no verification")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("\(badStem)-lev-18LUFS.wav").path),
                       "no output should be written for the failed input")
        XCTAssertTrue(info.contains { $0.contains("✗ \(badURL.lastPathComponent)") },
                      "the processing log should record the failure")
    }

    /// `onDeliveryComplete` fires exactly once, at the delivering-to-verifying
    /// boundary: after every input reaches a terminal outcome, while the
    /// verification pool is still draining. This is what the toolbar's
    /// Verifying state keys off (#24).
    ///
    /// What this pins is the boundary's contract — fires once, strictly after
    /// every delivery outcome, strictly before the tail ends. It deliberately
    /// does NOT assert that verifications overlap delivery. That overlap is
    /// real and is why `onVerificationProgress` cannot serve as this signal
    /// (see the pool comment in DeliveryProcessor.run), but whether it happens
    /// on a given run is a race: on short fixtures all deliveries can finish
    /// before the first verification does, which is exactly what this test
    /// observed while being written. Asserting it would be asserting a timing
    /// outcome, so the reason for the separate callback lives in the comments
    /// rather than in an assertion that passes by luck.
    func testDeliveryCompleteFiresOnceAtTheVerificationBoundary() async throws {
        let tools = try XCTUnwrap(tools)
        var jobs: [DeliveryJobInput] = []
        for i in 0..<3 {
            let url = try IntegrationFFmpeg.makeSineWAV(
                ffmpeg: tools.ffmpeg, directory: workDir, name: "boundary_\(i).wav",
                durationSeconds: 3.0, sampleRate: 44100
            )
            jobs.append(DeliveryJobInput(id: UUID(), url: url))
        }

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .both
        settings.mp3Bitrate = 160
        settings.outputDirectoryPath = workDir.path

        let events = EventCollector()
        let result = try await DeliveryProcessor().run(
            inputs: jobs,
            settings: settings,
            onFileCompleted: { _ in events.append("delivered") },
            onFileFailed: { _ in events.append("failed") },
            onPhase: { _, _ in },
            onDeliveryComplete: { events.append("deliveryComplete") },
            onVerificationProgress: { _ in events.append("verified") }
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.successes.count, 3)

        let ordered = events.snapshot()
        XCTAssertEqual(ordered.filter { $0 == "deliveryComplete" }.count, 1,
                       "onDeliveryComplete must fire exactly once, got: \(ordered)")

        let boundary = try XCTUnwrap(ordered.firstIndex(of: "deliveryComplete"))

        // Every file's terminal callback precedes the boundary — that is what
        // makes it safe for the toolbar to treat it as "all files written".
        let terminal = ordered.enumerated().filter { $0.element == "delivered" || $0.element == "failed" }
        XCTAssertEqual(terminal.count, 3)
        for (idx, _) in terminal {
            XCTAssertLessThan(idx, boundary,
                              "every delivery outcome must precede the boundary, got: \(ordered)")
        }

        // A real tail remains after the boundary. Each verification is an
        // ffmpeg invocation of hundreds of ms, while the gap between the last
        // file's yield and the boundary is microseconds — the same timing
        // argument testCancelAfterCompletionSkipsDeferredVerifications relies on.
        let verifiedAfter = ordered.suffix(from: boundary).filter { $0 == "verified" }.count
        XCTAssertGreaterThan(verifiedAfter, 0,
                             "verification work must remain after the boundary, got: \(ordered)")

        // 3 files x (WAV + MP3) = 6 verification passes, all accounted for.
        XCTAssertEqual(ordered.filter { $0 == "verified" }.count, 6)
    }

    // MARK: - Mono delivery (mono sources)

    /// (a) Mono source + mono delivery ON → a true single-channel WAV and MP3 that still
    /// land on target — there's no upmix happening to create a dual-mono +3 LU artifact.
    func testMonoDeliveryProducesSingleChannelOnTarget() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir, name: "mono_on.wav",
            durationSeconds: 4.0, sampleRate: 44100, channels: 1
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .both
        settings.mp3Bitrate = 160
        settings.monoDelivery = true
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")
        let job = try XCTUnwrap(result.successes.first)
        XCTAssertNil(job.mp3FailureMessage, "no MP3 sub-failure expected here")
        let outputs = job.outputURLs
        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))
        let mp3 = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "mp3" }))

        let wavChannels = try await channelCount(ffprobe: tools.ffprobe, of: wav)
        XCTAssertEqual(wavChannels, 1, "mono delivery should produce a single-channel WAV")
        let mp3Channels = try await channelCount(ffprobe: tools.ffprobe, of: mp3)
        XCTAssertEqual(mp3Channels, 1, "mono delivery should produce a single-channel MP3")

        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: wav)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.0,
                       "mono delivery should still hit target (no dual-mono +3 LU artifact)")
    }

    /// (b) Mono source + mono delivery OFF (default) → existing dual-mono-stereo behavior
    /// is completely unchanged. The regression guard that matters most.
    func testMonoDeliveryOffUpmixesToDualMonoStereo() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir, name: "mono_off.wav",
            durationSeconds: 4.0, sampleRate: 44100, channels: 1
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .wav
        settings.monoDelivery = false   // default
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")
        let job = try XCTUnwrap(result.successes.first)
        XCTAssertNil(job.mp3FailureMessage, "no MP3 sub-failure expected here")
        let outputs = job.outputURLs
        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))

        let wavChannels = try await channelCount(ffprobe: tools.ffprobe, of: wav)
        XCTAssertEqual(wavChannels, 2, "default (mono delivery off) must still upmix a mono source to dual-mono stereo")
        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: wav)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.0,
                       "upmix-before-loudnorm keeps a mono source on target, not +3 LU over")
    }

    /// (c) Stereo source → the mono-delivery control is inert regardless of its state: the
    /// output stays stereo even with monoDelivery forced on. This is not a downmix feature.
    func testStereoSourceIgnoresMonoDeliverySetting() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir, name: "stereo_src.wav",
            durationSeconds: 4.0, sampleRate: 44100, channels: 2
        )

        var settings = WaxOffSettings()
        settings.targetLUFS = -18.0
        settings.truePeak = -1.0
        settings.outputMode = .wav
        settings.monoDelivery = true    // on, but must be ignored for a stereo source
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")
        let job = try XCTUnwrap(result.successes.first)
        XCTAssertNil(job.mp3FailureMessage, "no MP3 sub-failure expected here")
        let outputs = job.outputURLs
        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))

        let wavChannels = try await channelCount(ffprobe: tools.ffprobe, of: wav)
        XCTAssertEqual(wavChannels, 2, "a stereo source must remain stereo regardless of the mono-delivery setting")
    }

    // MARK: -

    /// Drives `DeliveryProcessor.run` while capturing the processing-log
    /// stream, returning the produced outputs and the info-level log messages.
    private func runCapturingLog(input: URL, settings: WaxOffSettings) async throws -> (outputs: [URL], info: [String]) {
        let collector = LogCollector()
        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings,
            onLog: { message, level in collector.append(message, level) }
        )
        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail")
        let job = try XCTUnwrap(result.successes.first)
        return (job.outputURLs, collector.infoMessages)
    }

    /// Re-runs loudnorm pass-1 analysis on the given file and returns the
    /// integrated-loudness reading. Same parsing path the processor uses, so
    /// any drift in JSON handling shows up here too.
    private func measureIntegratedLoudness(ffmpeg: String, of url: URL) async throws -> Double {
        let stderr = try await FFmpegRunner.capture(exe: ffmpeg, args: [
            "-nostdin", "-hide_banner",
            "-i", url.path,
            "-af", "loudnorm=I=-23:TP=-1:LRA=9:print_format=json",
            "-f", "null", "/dev/null"
        ])
        let dict = try XCTUnwrap(FFmpegRunner.parseLoudnormJSON(from: stderr))
        let inputI = try XCTUnwrap(dict["input_i"])
        return try XCTUnwrap(Double(inputI))
    }

    /// A single format-level ID3 tag's exact value via ffprobe (e.g. "title", "album").
    private func formatTag(_ key: String, ffprobe: String, of url: URL) async throws -> String {
        let out = try await FFmpegRunner.captureStdout(exe: ffprobe, args: [
            "-v", "error", "-show_entries", "format_tags=\(key)",
            "-of", "default=nw=1:nk=1", url.path
        ])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Channel count of audio stream a:0 via ffprobe.
    private func channelCount(ffprobe: String, of url: URL) async throws -> Int {
        let out = try await FFmpegRunner.captureStdout(exe: ffprobe, args: [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=channels", "-of", "default=nw=1:nk=1", url.path
        ])
        return try XCTUnwrap(Int(out.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    // MARK: - Podcast metadata

    /// Encodes a fully tagged MP3 and probes it back. This is the only test
    /// that proves the ID3 frames actually land — the argument tests prove we
    /// build the right command, not that FFmpeg honours it.
    func testDeliveredMP3CarriesChaptersArtworkAndTags() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "id3_in.wav",
            durationSeconds: 9.0,
            sampleRate: 44100
        )

        // Artwork is embedded with -c:v copy (never decoded or resized), so
        // its exact size is irrelevant to the code path under test — Apple's
        // 1400px minimum is a UI-level warning added in a later task, not
        // something production reads here. Kept small to keep this test fast.
        let artwork = workDir.appendingPathComponent("cover.png")
        try await FFmpegRunner.run(exe: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=darkblue:s=400x400",
            "-frames:v", "1", artwork.path
        ], fileDuration: nil)

        var metadata = EpisodeMetadata()
        metadata.podcastName = "Test Podcast"
        metadata.episodeTitle = "Episode 42"
        metadata.artworkURL = artwork
        metadata.chapters = [
            Chapter(start: 0, title: "Cold Open"),
            Chapter(start: 3, title: "Main Interview"),
            Chapter(start: 6, title: "Outro")
        ]

        var settings = WaxOffSettings()
        settings.outputMode = .mp3
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input, metadata: metadata)],
            settings: settings
        )

        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail: \(result.failures)")
        let job = try XCTUnwrap(result.successes.first)
        let mp3 = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "mp3" }))

        let chapterJSON = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_chapters", "-of", "json", mp3.path
        ])
        XCTAssertTrue(chapterJSON.contains("Cold Open"), "missing chapter 1 in:\n\(chapterJSON)")
        XCTAssertTrue(chapterJSON.contains("Main Interview"), "missing chapter 2")
        XCTAssertTrue(chapterJSON.contains("Outro"), "missing chapter 3")

        let streamJSON = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_streams", "-of", "json", mp3.path
        ])
        XCTAssertTrue(streamJSON.contains("\"attached_pic\": 1"), "no attached cover art in:\n\(streamJSON)")

        let title = try await formatTag("title", ffprobe: tools.ffprobe, of: mp3)
        XCTAssertEqual(title, "Episode 42", "title tag mismatch")
        let album = try await formatTag("album", ffprobe: tools.ffprobe, of: mp3)
        XCTAssertEqual(album, "Test Podcast", "album tag mismatch")

        // Guards mp3Arguments' index arithmetic (audio=0, chapters=1,
        // artwork=2): a mis-mapped stream could pass the tag assertions above
        // while delivering the wrong — or truncated/absent — audio.
        let durationStr = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1", mp3.path
        ])
        let duration = try XCTUnwrap(Double(durationStr.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(duration, 9.0, accuracy: 0.5, "delivered MP3 duration should match the 9s fixture")
    }

    /// An untagged file must deliver exactly as it did before this feature.
    func testUntaggedDeliveryWritesNoChaptersOrArtwork() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "no_id3_in.wav",
            durationSeconds: 5.0,
            sampleRate: 44100
        )

        var settings = WaxOffSettings()
        settings.outputMode = .mp3
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input)],
            settings: settings
        )

        XCTAssertTrue(result.failures.isEmpty)
        let job = try XCTUnwrap(result.successes.first)
        let mp3 = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "mp3" }))

        let chapterJSON = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_chapters", "-of", "json", mp3.path
        ])
        XCTAssertFalse(chapterJSON.contains("\"id\""), "untagged delivery must have no chapters:\n\(chapterJSON)")

        let streamJSON = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_streams", "-of", "json", mp3.path
        ])
        XCTAssertFalse(streamJSON.contains("\"attached_pic\": 1"), "untagged delivery must have no cover art")
    }

    // MARK: - Metadata degradation

    /// Artwork that vanished between tagging and delivery must cost the cover,
    /// not the delivery. In MP3-only mode a thrown error is a total failure.
    func testMissingArtworkStillDelivers() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir,
            name: "missing_art.wav", durationSeconds: 4.0, sampleRate: 44100
        )

        var metadata = EpisodeMetadata()
        metadata.episodeTitle = "Still Delivers"
        metadata.artworkURL = workDir.appendingPathComponent("does-not-exist.png")

        var settings = WaxOffSettings()
        settings.outputMode = .mp3
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input, metadata: metadata)],
            settings: settings
        )

        XCTAssertTrue(result.failures.isEmpty, "missing artwork must not fail the delivery: \(result.failures)")
        let job = try XCTUnwrap(result.successes.first)
        let mp3 = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "mp3" }))
        let streamJSON = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_streams", "-of", "json", mp3.path
        ])
        XCTAssertFalse(streamJSON.contains("\"attached_pic\": 1"), "expected no cover art")
    }

    /// A directory passed as artwork passes `isReadableFile`, so it needs its
    /// own check — otherwise it reaches ffmpeg as `-i <dir>` and fails the
    /// whole MP3-only delivery.
    func testDirectoryAsArtworkStillDelivers() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir,
            name: "dir_art.wav", durationSeconds: 4.0, sampleRate: 44100
        )

        let dir = workDir.appendingPathComponent("not-an-image", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var metadata = EpisodeMetadata()
        metadata.artworkURL = dir

        var settings = WaxOffSettings()
        settings.outputMode = .mp3
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input, metadata: metadata)],
            settings: settings
        )

        XCTAssertTrue(result.failures.isEmpty, "a directory as artwork must not fail the delivery: \(result.failures)")
        let job = try XCTUnwrap(result.successes.first)
        let mp3 = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "mp3" }))
        let streamJSON = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_streams", "-of", "json", mp3.path
        ])
        XCTAssertFalse(streamJSON.contains("\"attached_pic\": 1"), "a directory must not be embedded as cover art")
    }

    /// Chapters past the end of the audio are dropped, not written with an END
    /// preceding their START.
    func testChaptersPastEndOfAudioAreDropped() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir,
            name: "past_end.wav", durationSeconds: 6.0, sampleRate: 44100
        )

        var metadata = EpisodeMetadata()
        metadata.chapters = [
            Chapter(start: 0, title: "Kept"),
            Chapter(start: 600, title: "Dropped")
        ]

        var settings = WaxOffSettings()
        settings.outputMode = .mp3
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input, metadata: metadata)],
            settings: settings
        )

        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail: \(result.failures)")
        let job = try XCTUnwrap(result.successes.first)
        let mp3 = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "mp3" }))
        let chapterJSON = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_chapters", "-of", "json", mp3.path
        ])
        XCTAssertTrue(chapterJSON.contains("Kept"), "in-range chapter missing:\n\(chapterJSON)")
        XCTAssertFalse(chapterJSON.contains("Dropped"), "out-of-range chapter must be dropped:\n\(chapterJSON)")
    }

    /// Titles that are not Latin-1 representable must survive: ID3v2.3 has no
    /// UTF-8, so FFmpeg falls back to UTF-16 rather than mangling them.
    func testNonASCIITagsRoundTrip() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir,
            name: "unicode.wav", durationSeconds: 4.0, sampleRate: 44100
        )

        var metadata = EpisodeMetadata()
        metadata.episodeTitle = "Episode 12 — What’s Next? café 日本語"
        metadata.podcastName = "Señor Show"

        var settings = WaxOffSettings()
        settings.outputMode = .mp3
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input, metadata: metadata)],
            settings: settings
        )

        XCTAssertTrue(result.failures.isEmpty)
        let job = try XCTUnwrap(result.successes.first)
        let mp3 = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "mp3" }))

        let title = try await formatTag("title", ffprobe: tools.ffprobe, of: mp3)
        XCTAssertEqual(title, "Episode 12 — What’s Next? café 日本語", "unicode title mangled")
        let album = try await formatTag("album", ffprobe: tools.ffprobe, of: mp3)
        XCTAssertEqual(album, "Señor Show", "unicode album mangled")
    }

    /// In `.both` mode only the MP3 is tagged — the WAV is moved into place
    /// without going through `encodeMP3` at all. Currently true by
    /// construction; this pins it so a future refactor cannot quietly change it.
    func testBothModeTagsOnlyTheMP3() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir,
            name: "both_mode.wav", durationSeconds: 6.0, sampleRate: 44100
        )

        var metadata = EpisodeMetadata()
        metadata.podcastName = "Both Mode Show"
        metadata.chapters = [Chapter(start: 0, title: "One"), Chapter(start: 3, title: "Two")]

        var settings = WaxOffSettings()
        settings.outputMode = .both
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input, metadata: metadata)],
            settings: settings
        )

        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail: \(result.failures)")
        let job = try XCTUnwrap(result.successes.first)
        let mp3 = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "mp3" }))
        let wav = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "wav" }))

        let mp3Chapters = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_chapters", "-of", "json", mp3.path
        ])
        XCTAssertTrue(mp3Chapters.contains("One"), "MP3 should carry chapters:\n\(mp3Chapters)")

        let wavChapters = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_chapters", "-of", "json", wav.path
        ])
        XCTAssertFalse(wavChapters.contains("One"), "WAV must not carry chapters:\n\(wavChapters)")
    }

    /// Chapter titles containing ffmetadata's special characters must survive
    /// a real mux. The unit tests assert the escaped string we generate; only
    /// this proves FFmpeg parses it back to the original.
    func testChapterTitlesWithSpecialCharactersSurvive() async throws {
        let tools = try XCTUnwrap(tools)
        let input = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg, directory: workDir,
            name: "escaping.wav", durationSeconds: 9.0, sampleRate: 44100
        )

        var metadata = EpisodeMetadata()
        metadata.chapters = [
            Chapter(start: 0, title: "Intro = Part 1"),
            Chapter(start: 3, title: "Notes; see #2"),
            Chapter(start: 6, title: #"Back\slash"#)
        ]

        var settings = WaxOffSettings()
        settings.outputMode = .mp3
        settings.outputDirectoryPath = workDir.path

        let result = try await DeliveryProcessor().run(
            inputs: [DeliveryJobInput(id: UUID(), url: input, metadata: metadata)],
            settings: settings
        )

        XCTAssertTrue(result.failures.isEmpty, "delivery must not fail: \(result.failures)")
        let job = try XCTUnwrap(result.successes.first)
        let mp3 = try XCTUnwrap(job.outputURLs.first(where: { $0.pathExtension == "mp3" }))
        let json = try await FFmpegRunner.captureStdout(exe: tools.ffprobe, args: [
            "-v", "error", "-show_chapters", "-of", "json", mp3.path
        ])
        XCTAssertTrue(json.contains("Intro = Part 1"), "equals mangled:\n\(json)")
        XCTAssertTrue(json.contains("Notes; see #2"), "semicolon/hash mangled:\n\(json)")
        // ffprobe's JSON escapes a literal backslash as \\ — assert the encoded form.
        XCTAssertTrue(json.contains(#"Back\\slash"#), "backslash mangled:\n\(json)")
    }
}

/// Thread-safe ordered event sink for callbacks firing from the processor's
/// concurrency domain (completions, log lines) so ordering can be asserted.
nonisolated private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Holds the test's Task handle so a processor callback can cancel it.
nonisolated private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<DeliveryBatchRunResult, Error>?

    func set(_ t: Task<DeliveryBatchRunResult, Error>) {
        lock.lock(); defer { lock.unlock() }
        task = t
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
    }
}

/// Thread-safe sink for the `onLog` callback, which fires from the processor's
/// concurrency domain. Lets a test collect log lines and inspect them after the
/// awaited run completes.
nonisolated private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(message: String, level: LogLevel)] = []

    func append(_ message: String, _ level: LogLevel) {
        lock.lock(); defer { lock.unlock() }
        lines.append((message, level))
    }

    var infoMessages: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines.compactMap { line in
            if case .info = line.level { return line.message }
            return nil
        }
    }

    var verboseMessages: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines.compactMap { line in
            if case .verbose = line.level { return line.message }
            return nil
        }
    }
}
