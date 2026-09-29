import XCTest
@testable import WaxOnWaxOff

/// WaxOn's half of the Cancel-then-Process race; WaxOff's is in
/// `DeliveryViewModelRestartWindowTests`. Driven against a real
/// `AudioProcessor` run, because what went wrong was a cancelled batch's
/// cleanup landing late, after the next batch had started.
///
/// Requires the bundled FFmpeg binaries — `XCTSkip`s cleanly without them.
@MainActor
final class ContentViewModelCancelTests: XCTestCase {

    private var workDir: URL!
    private var scratch: ScratchDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxon-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        scratch = try ScratchDefaults()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        scratch?.remove()
        scratch = nil
        try super.tearDownWithError()
    }

    /// Cancel, then Process in the same turn — a double-click on Cancel, which
    /// the header replaces in place with Process. The cancelled batch's cleanup
    /// used to clear `isProcessing` and `processingTask` under the new batch,
    /// which hid its Cancel button and left nothing able to stop it.
    func testCancelledBatchCleanupLeavesTheNextBatchAlone() async throws {
        let tools = try IntegrationFFmpeg.locate()
        // Changing the settings saves them, so the view model gets a store of
        // its own rather than the developer's real one.
        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.settings.outputDirectoryPath = workDir.path
        vm.files = try ["a", "b"].map { name in
            let url = try IntegrationFFmpeg.makeSineWAV(
                ffmpeg: tools.ffmpeg, directory: workDir, name: "\(name).wav",
                durationSeconds: 600, sampleRate: 44100
            )
            var item = FileItem(url: url)
            item.status = .ready(AudioStats(rms: -20, peak: -3, crest: 17, lufs: -20))
            return item
        }

        vm.process()
        let deadline = Date().addingTimeInterval(60)
        while !vm.files.contains(where: { $0.status == .processing }) {
            guard Date() < deadline else { return XCTFail("the first batch never started a file") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let first = try XCTUnwrap(vm.processingTask)

        vm.cancelProcessing()
        vm.process()
        XCTAssertTrue(vm.isProcessing, "the second press must start a batch")

        // Let the cancelled batch finish unwinding, cleanup included.
        _ = await first.value

        XCTAssertTrue(vm.isProcessing, "the cancelled batch's cleanup must not end the new batch")
        let second = try XCTUnwrap(vm.processingTask, "the new batch must still be cancellable")

        vm.cancelProcessing()
        _ = await second.value
        XCTAssertFalse(vm.isProcessing)
        XCTAssertEqual(try IntegrationFFmpeg.processCount(mentioning: workDir.path), 0,
                       "cancelling the new batch must leave no ffmpeg running")
    }
}
