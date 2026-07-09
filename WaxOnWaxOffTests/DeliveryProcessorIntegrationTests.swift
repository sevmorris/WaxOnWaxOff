import XCTest
@testable import WaxOnWaxOff

/// End-to-end WaxOff tests — drive `DeliveryProcessor.process` against a
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

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
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

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
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

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
        let mp3 = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "mp3" }))

        let measuredI = try await measureIntegratedLoudness(ffmpeg: tools.ffmpeg, of: mp3)
        XCTAssertEqual(measuredI, settings.targetLUFS, accuracy: 1.5,
                       "MP3 encode may drift slightly from WAV; allow wider tolerance")
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

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
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

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
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

        let outputs = try await DeliveryProcessor().process(url: input, settings: settings)
        let wav = try XCTUnwrap(outputs.first(where: { $0.pathExtension == "wav" }))

        let wavChannels = try await channelCount(ffprobe: tools.ffprobe, of: wav)
        XCTAssertEqual(wavChannels, 2, "a stereo source must remain stereo regardless of the mono-delivery setting")
    }

    // MARK: -

    /// Drives `DeliveryProcessor.process` while capturing the processing-log
    /// stream, returning the produced outputs and the info-level log messages.
    private func runCapturingLog(input: URL, settings: WaxOffSettings) async throws -> (outputs: [URL], info: [String]) {
        let collector = LogCollector()
        let outputs = try await DeliveryProcessor().process(
            url: input,
            settings: settings,
            onLog: { message, level in collector.append(message, level) }
        )
        return (outputs, collector.infoMessages)
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

    /// Channel count of audio stream a:0 via ffprobe.
    private func channelCount(ffprobe: String, of url: URL) async throws -> Int {
        let out = try await FFmpegRunner.captureStdout(exe: ffprobe, args: [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=channels", "-of", "default=nw=1:nk=1", url.path
        ])
        return try XCTUnwrap(Int(out.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

/// Thread-safe ordered event sink for callbacks firing from the processor's
/// concurrency domain (completions, log lines) so ordering can be asserted.
private final class EventCollector: @unchecked Sendable {
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
private final class TaskBox: @unchecked Sendable {
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
private final class LogCollector: @unchecked Sendable {
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
}
