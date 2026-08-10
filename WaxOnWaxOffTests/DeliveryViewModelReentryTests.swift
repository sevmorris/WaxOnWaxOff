import XCTest
@testable import WaxOnWaxOff

/// The re-entry gate that decides whether `process()` starts a batch or returns.
///
/// Asserted through `canStartNewBatch` rather than by driving a real batch: the
/// verification tail is a timing window, and asserting against it directly is
/// the trap the #24 boundary test hit. The decision is pure state, so it can be
/// pinned exactly.
@MainActor
final class DeliveryViewModelReentryTests: XCTestCase {

    func testIdleStarts() {
        let vm = DeliveryViewModel()
        vm.isProcessing = false
        vm.isVerifying = false
        XCTAssertTrue(vm.canStartNewBatch, "an idle view model must start")
    }

    /// The gate. A drop-and-start during active delivery would abandon renders
    /// in progress — unlike the tail, where every file is already written.
    func testActiveDeliveryDoesNotStart() {
        let vm = DeliveryViewModel()
        vm.isProcessing = true
        vm.isVerifying = false
        XCTAssertFalse(vm.canStartNewBatch,
                       "a batch that is still delivering must not be restartable")
    }

    /// The window this change opens: delivery finished, only the advisory
    /// re-measurement outstanding.
    func testVerificationTailStarts() {
        let vm = DeliveryViewModel()
        vm.isProcessing = true
        vm.isVerifying = true
        XCTAssertTrue(vm.canStartNewBatch,
                      "the verification tail must be restartable")
    }

    /// Delivered rows are `.processed`, and the batch only ever takes `.ready`
    /// rows — so a restart cannot pick up the previous batch's files. Pins that
    /// the two statuses are distinct and that `.processed` is not `.ready`.
    func testProcessedRowsAreNotReady() {
        let processed = FileStatus.processed(outputURL: URL(fileURLWithPath: "/tmp/out.wav"))
        if case .ready = processed {
            XCTFail("a delivered row must not read as .ready, or a restart would reprocess it")
        }
    }
}

/// The restart window itself, driven against a real `DeliveryProcessor` run.
///
/// The predicate tests above pin what `process()` decides; they cannot catch
/// what actually went wrong here, which was a second caller arriving partway
/// through a restart. That needs the real sequence: a live batch, a genuine
/// cancellation, and a real unwind to race against.
///
/// Requires the bundled FFmpeg binaries — `XCTSkip`s cleanly without them, the
/// same as the other integration suites.
@MainActor
final class DeliveryViewModelRestartWindowTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxoff-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    /// The window the flag closes.
    ///
    /// Getting *to* the verification tail is timing-dependent, so it is polled
    /// for rather than assumed — the trap the #24 boundary test fell into. What
    /// is asserted once there is not timing-dependent at all: both presses run
    /// in one main-actor turn with no suspension between them, so the second
    /// sees precisely the state the first left. That state is `isProcessing ==
    /// false`, because `cancelProcessing()` clears it synchronously — which is
    /// why, before the flag, the second press fell through to the start path and
    /// began a batch that the first batch's cleanup then orphaned.
    func testSecondPressInsideRestartWindowStartsNothing() async throws {
        let vm = try makeViewModel(named: ["a", "b", "c"])

        vm.process()
        XCTAssertTrue(vm.isProcessing, "the first press must start a batch")

        try await waitForVerificationTail(vm)

        // A file dropped during the tail — the flow the whole feature exists for.
        vm.files.append(try makeReadyItem(named: "dropped"))

        // Press one: cancels the outstanding batch and schedules the restart.
        vm.process()
        XCTAssertTrue(vm.isRestarting, "a press during the tail must schedule a restart")
        XCTAssertFalse(vm.isProcessing, "cancelProcessing() clears this synchronously — the window")

        // Press two, same turn, nothing awaited in between. This is the race.
        vm.process()
        XCTAssertFalse(vm.isProcessing,
                       "a second press inside the restart window must not start a batch")
        XCTAssertTrue(vm.isRestarting, "and must leave the scheduled restart intact")

        try await waitForIdle(vm)

        // The guard must refuse the extra press without swallowing the restart:
        // the dropped file still gets delivered, and the flag does not stick.
        XCTAssertFalse(vm.isRestarting, "the flag must clear once the restart re-enters")
        let dropped = try XCTUnwrap(vm.files.first { $0.url.lastPathComponent == "dropped.wav" })
        guard case .processed = dropped.status else {
            return XCTFail("the restart must still deliver the dropped file, got \(dropped.status)")
        }
    }

    // MARK: - Fixtures

    /// A view model holding real, already-analysed inputs, so `process()` runs a
    /// genuine batch without waiting on the analyser. The custom output
    /// directory matters beyond tidiness: it keeps the resolver off ~/Desktop,
    /// and `confirmDesktopFallback` puts up a modal `NSAlert` when more than one
    /// output lands there, which would hang the run.
    private func makeViewModel(named names: [String]) throws -> DeliveryViewModel {
        let vm = DeliveryViewModel()
        vm.settings.outputDirectoryPath = workDir.path
        vm.settings.outputMode = .wav
        vm.files = try names.map { try makeReadyItem(named: $0) }
        return vm
    }

    private func makeReadyItem(named name: String) throws -> FileItem {
        let tools = try IntegrationFFmpeg.locate()
        let url = try IntegrationFFmpeg.makeSineWAV(
            ffmpeg: tools.ffmpeg,
            directory: workDir,
            name: "\(name).wav",
            durationSeconds: 3.0,
            sampleRate: 44100
        )
        var item = FileItem(url: url)
        // `.ready` with stats is what the ready-file filter takes; `fileInfo`
        // has to be non-nil or `process()` fails the row closed on unknown
        // channel count before any batch starts.
        item.status = .ready(AudioStats(rms: -20, peak: -3, crest: 17, lufs: -20))
        item.fileInfo = FileInfo(
            format: "wav", sampleRate: 44100, channelCount: 1,
            bitDepth: 16, duration: 3.0, bitRate: nil
        )
        return item
    }

    // MARK: - Waits

    private func waitForVerificationTail(
        _ vm: DeliveryViewModel,
        timeout: TimeInterval = 120
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !vm.isVerifying {
            guard vm.isProcessing else {
                // Skipped rather than failed: the tail is real but short, and a
                // machine fast enough to close it before the poll sees it has
                // not found a bug. A failure here would be noise.
                throw XCTSkip("batch completed before the verification tail was observable")
            }
            guard Date() < deadline else {
                return XCTFail("never reached the verification tail within \(Int(timeout))s")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitForIdle(
        _ vm: DeliveryViewModel,
        timeout: TimeInterval = 180
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while vm.isProcessing || vm.isRestarting {
            guard Date() < deadline else {
                return XCTFail("view model never returned to idle within \(Int(timeout))s")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
