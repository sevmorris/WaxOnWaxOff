import XCTest
@testable import WaxOnWaxOff

/// Which sources a finished WaxOn batch sends to the Trash, and where the
/// switch is kept. The batch itself, with FFmpeg, is in
/// `AudioProcessorIntegrationTests`.
@MainActor
final class TrashOriginalsTests: XCTestCase {
    private var scratch: ScratchDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try ScratchDefaults()
    }

    override func tearDownWithError() throws {
        scratch?.remove()
        scratch = nil
        try super.tearDownWithError()
    }

    private let a = URL(fileURLWithPath: "/Recordings/a.wav")
    private let b = URL(fileURLWithPath: "/Recordings/b.wav")
    private let c = URL(fileURLWithPath: "/Recordings/c.wav")

    private func output(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("out.wav")
    }

    private func success(_ input: JobInput) -> JobResult {
        JobResult(id: input.id, input: input.url, outputs: [output(for: input.url)])
    }

    private func failure(_ input: JobInput) -> WaxOnJobFailure {
        WaxOnJobFailure(id: input.id, message: "failed")
    }

    func testEverySucceededSourceIsTrashedInQueueOrder() {
        let inputs = [c, a, b].map { JobInput(id: UUID(), url: $0) }
        let trashed = AudioProcessor.sourcesToTrash(
            inputs: inputs,
            successes: inputs.reversed().map(success),
            failures: []
        )
        XCTAssertEqual(trashed, [c, a, b])
    }

    func testAFailedSourceKeepsItsOriginal() {
        let ok = JobInput(id: UUID(), url: a)
        let bad = JobInput(id: UUID(), url: b)
        let trashed = AudioProcessor.sourcesToTrash(
            inputs: [ok, bad],
            successes: [success(ok)],
            failures: [failure(bad)]
        )
        XCTAssertEqual(trashed, [a])
    }

    func testASourceQueuedTwiceIsKeptWhenEitherJobFailed() {
        let first = JobInput(id: UUID(), url: a)
        let second = JobInput(id: UUID(), url: a)
        let trashed = AudioProcessor.sourcesToTrash(
            inputs: [first, second],
            successes: [success(first)],
            failures: [failure(second)]
        )
        XCTAssertEqual(trashed, [])
    }

    func testASourceQueuedTwiceIsTrashedOnce() {
        let first = JobInput(id: UUID(), url: a)
        let second = JobInput(id: UUID(), url: URL(fileURLWithPath: "/Recordings/./a.wav"))
        let trashed = AudioProcessor.sourcesToTrash(
            inputs: [first, second],
            successes: [success(first), success(second)],
            failures: []
        )
        XCTAssertEqual(trashed, [a])
    }

    func testASourceThatIsAlsoAnOutputIsKept() {
        let input = JobInput(id: UUID(), url: a)
        let other = JobInput(id: UUID(), url: b)
        let trashed = AudioProcessor.sourcesToTrash(
            inputs: [input, other],
            successes: [
                success(input),
                JobResult(id: other.id, input: b, outputs: [a]),
            ],
            failures: []
        )
        XCTAssertEqual(trashed, [b])
    }

    func testTheSwitchIsOffUntilTurnedOn() {
        XCTAssertFalse(ContentViewModel(defaults: scratch.defaults).trashOriginals)
    }

    func testTheSwitchComesBackFromTheSameStore() {
        ContentViewModel(defaults: scratch.defaults).trashOriginals = true
        XCTAssertTrue(ContentViewModel(defaults: scratch.defaults).trashOriginals)
    }

    /// A preset is applied on every launch it is selected for, so a switch
    /// stored in `WaxOnSettings` would be turned off, or on, by that.
    func testAPresetNeverChangesTheSwitch() throws {
        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.trashOriginals = true
        vm.applyPreset(try XCTUnwrap(WaxOnPreset.builtIn.first))
        XCTAssertTrue(vm.trashOriginals)
        XCTAssertTrue(ContentViewModel(defaults: scratch.defaults).trashOriginals)
    }
}
