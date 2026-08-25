import XCTest
@testable import WaxOnWaxOff

/// Where a skipped file gets reported, and how loudly.
///
/// Adding a folder that holds anything besides audio used to raise a modal
/// titled "Error" — even when every audio file in it loaded. A folder with a
/// `readme.txt` in it is the ordinary case rather than a failure, so the rule
/// pinned here is that the alert is reserved for an add that produced nothing
/// and everything else is a Console line.
@MainActor
final class AddFilesSkipReportTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxonwaxoff-addfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// `addFiles` classifies on the path extension alone, so the contents of
    /// these files never matter — only that the folder walk finds them.
    private func makeFolder(_ name: String, containing files: [String]) throws -> URL {
        let folder = workDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data().write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    /// A folder of audio with one stray non-audio file — the case that used to
    /// raise "Error".
    private func makeMixedFolder(_ name: String = "mixed") throws -> URL {
        try makeFolder(name, containing: ["take-1.wav", "take-2.wav", "notes.txt"])
    }

    private func skipMessage(_ count: Int) -> String {
        "skipped \(count)"
    }

    /// Console lines the user actually sees — `ConsoleView` hides `.verbose`
    /// unless the Verbose box is ticked, so a notice filed there would be no
    /// better than the silence this fix replaces.
    private func visibleConsoleLines(_ log: ProcessingLog) -> [String] {
        log.entries.filter { $0.level == .info }.map(\.message)
    }

    // MARK: - The classification

    func testSkipAlongsideLoadedFilesIsANotice() throws {
        let queue = FileQueueCoordinator()
        defer { queue.clearAll() }

        let report = queue.addFiles([try makeMixedFolder()], skippedFormatMessage: skipMessage)

        guard case .notice(let message) = report else {
            return XCTFail("a skip with audio loaded must not interrupt: got \(String(describing: report))")
        }
        XCTAssertEqual(message, "skipped 1")
        XCTAssertEqual(queue.files.count, 2, "both audio files should still have loaded")
    }

    func testSkippingEverythingIsAnAlert() throws {
        let queue = FileQueueCoordinator()
        let folder = try makeFolder("no-audio", containing: ["notes.txt", "cover.png"])

        let report = queue.addFiles([folder], skippedFormatMessage: skipMessage)

        guard case .alert(let message) = report else {
            return XCTFail("an add that loaded nothing has to say so: got \(String(describing: report))")
        }
        XCTAssertEqual(message, "skipped 2")
        XCTAssertTrue(queue.files.isEmpty)
    }

    func testNothingSkippedReportsNothing() throws {
        let queue = FileQueueCoordinator()
        defer { queue.clearAll() }
        let folder = try makeFolder("clean", containing: ["take-1.wav", "take-2.aiff"])

        XCTAssertNil(queue.addFiles([folder], skippedFormatMessage: skipMessage))
        XCTAssertEqual(queue.files.count, 2)
    }

    /// `expandFolder` enumerates with `.skipsHiddenFiles`, so the dotfiles macOS
    /// leaves lying about never reach the count. Pinned because a `.DS_Store`
    /// counted as a skip would fire this report on a folder of nothing but audio.
    func testHiddenFilesAreNotCountedAsSkips() throws {
        let queue = FileQueueCoordinator()
        defer { queue.clearAll() }
        let folder = try makeFolder("hidden", containing: ["take-1.wav", ".DS_Store"])

        XCTAssertNil(queue.addFiles([folder], skippedFormatMessage: skipMessage),
                     "a hidden file is not something the user chose to add")
        XCTAssertEqual(queue.files.count, 1)
    }

    /// The already-processed sheets defer the commit rather than cancelling it,
    /// and a notice must survive that as a notice: stacking an "Error" modal
    /// behind "Already Processed?" is exactly the pile-up being removed.
    func testDeferredCommitStillReportsANotice() throws {
        let queue = FileQueueCoordinator()

        let report = queue.addFiles(
            [try makeMixedFolder()],
            skippedFormatMessage: skipMessage,
            beforeCommit: { _ in false }
        )

        guard case .notice = report else {
            return XCTFail("files held for confirmation still count as loaded: got \(String(describing: report))")
        }
        XCTAssertTrue(queue.files.isEmpty, "nothing should commit while the sheet decides")
    }

    // MARK: - WaxOn routing

    func testWaxOnMixedFolderGoesToTheConsole() throws {
        let vm = ContentViewModel()
        defer { vm.fileQueue.clearAll() }

        vm.addFiles([try makeMixedFolder()])

        XCTAssertNil(vm.alertMessage, "skipping a stray file is not worth a modal")
        let line = try XCTUnwrap(visibleConsoleLines(vm.log).first, "the skip belongs on the Console")
        XCTAssertTrue(line.contains("1 file skipped"), "unexpected wording: \(line)")
        XCTAssertTrue(line.contains("wav"), "the notice should still name the supported formats")
        XCTAssertEqual(vm.files.count, 2)
    }

    func testWaxOnFolderWithNoAudioAlerts() throws {
        let vm = ContentViewModel()
        let folder = try makeFolder("waxon-no-audio", containing: ["notes.txt", "cover.png"])

        vm.addFiles([folder])

        let message = try XCTUnwrap(vm.alertMessage, "an add that loaded nothing must interrupt")
        XCTAssertTrue(message.contains("2 files skipped"), "unexpected wording: \(message)")
        XCTAssertTrue(vm.log.entries.isEmpty, "an alert shouldn't also be logged")
        XCTAssertTrue(vm.files.isEmpty)
    }

    func testWaxOnCleanFolderSaysNothing() throws {
        let vm = ContentViewModel()
        defer { vm.fileQueue.clearAll() }

        vm.addFiles([try makeFolder("waxon-clean", containing: ["take-1.wav"])])

        XCTAssertNil(vm.alertMessage)
        XCTAssertTrue(vm.log.entries.isEmpty)
        XCTAssertEqual(vm.files.count, 1)
    }

    // MARK: - WaxOff routing

    func testWaxOffMixedFolderGoesToTheConsole() throws {
        let vm = DeliveryViewModel()
        defer { vm.fileQueue.clearAll() }

        vm.addFiles([try makeMixedFolder()])

        XCTAssertNil(vm.alertMessage, "skipping a stray file is not worth a modal")
        let line = try XCTUnwrap(visibleConsoleLines(vm.log).first, "the skip belongs on the Console")
        XCTAssertTrue(line.contains("1 file skipped"), "unexpected wording: \(line)")
        XCTAssertTrue(line.contains("wav"), "the notice should still name the supported formats")
        XCTAssertEqual(vm.files.count, 2)
    }

    func testWaxOffFolderWithNoAudioAlerts() throws {
        let vm = DeliveryViewModel()
        let folder = try makeFolder("waxoff-no-audio", containing: ["notes.txt", "cover.png"])

        vm.addFiles([folder])

        let message = try XCTUnwrap(vm.alertMessage, "an add that loaded nothing must interrupt")
        XCTAssertTrue(message.contains("2 files skipped"), "unexpected wording: \(message)")
        XCTAssertTrue(vm.log.entries.isEmpty, "an alert shouldn't also be logged")
        XCTAssertTrue(vm.files.isEmpty)
    }

    func testWaxOffCleanFolderSaysNothing() throws {
        let vm = DeliveryViewModel()
        defer { vm.fileQueue.clearAll() }

        vm.addFiles([try makeFolder("waxoff-clean", containing: ["take-1.wav"])])

        XCTAssertNil(vm.alertMessage)
        XCTAssertTrue(vm.log.entries.isEmpty)
        XCTAssertEqual(vm.files.count, 1)
    }

    // MARK: - A fresh add replaces the last one's message

    /// `addFiles` writes `alertMessage` on every add, not only when it has an
    /// alert to raise — otherwise an add that succeeded would leave the
    /// previous failure sitting on screen. The empty-array guards at the three
    /// call sites (the drop, the File menu, the `+` button) exist because of
    /// this, and their comments say so, so it has to stay true.
    func testWaxOnSuccessfulAddClearsAStaleAlert() throws {
        let vm = ContentViewModel()
        defer { vm.fileQueue.clearAll() }

        vm.addFiles([try makeFolder("waxon-stale", containing: ["notes.txt"])])
        XCTAssertNotNil(vm.alertMessage, "precondition: the first add should have alerted")

        vm.addFiles([try makeFolder("waxon-after", containing: ["take-1.wav"])])
        XCTAssertNil(vm.alertMessage, "an add that worked must not leave the previous failure up")
    }

    /// The same for an add that partially worked: its skip goes to the Console,
    /// and the alert the previous add raised still comes down.
    func testWaxOnNoticeClearsAStaleAlert() throws {
        let vm = ContentViewModel()
        defer { vm.fileQueue.clearAll() }

        vm.addFiles([try makeFolder("waxon-stale-2", containing: ["notes.txt"])])
        XCTAssertNotNil(vm.alertMessage, "precondition: the first add should have alerted")

        vm.addFiles([try makeMixedFolder("waxon-after-2")])
        XCTAssertNil(vm.alertMessage, "a notice replaces the stale alert rather than queueing behind it")
        XCTAssertEqual(visibleConsoleLines(vm.log).count, 1)
    }

    func testWaxOffSuccessfulAddClearsAStaleAlert() throws {
        let vm = DeliveryViewModel()
        defer { vm.fileQueue.clearAll() }

        vm.addFiles([try makeFolder("waxoff-stale", containing: ["notes.txt"])])
        XCTAssertNotNil(vm.alertMessage, "precondition: the first add should have alerted")

        vm.addFiles([try makeFolder("waxoff-after", containing: ["take-1.wav"])])
        XCTAssertNil(vm.alertMessage, "an add that worked must not leave the previous failure up")
    }

    func testWaxOffNoticeClearsAStaleAlert() throws {
        let vm = DeliveryViewModel()
        defer { vm.fileQueue.clearAll() }

        vm.addFiles([try makeFolder("waxoff-stale-2", containing: ["notes.txt"])])
        XCTAssertNotNil(vm.alertMessage, "precondition: the first add should have alerted")

        vm.addFiles([try makeMixedFolder("waxoff-after-2")])
        XCTAssertNil(vm.alertMessage, "a notice replaces the stale alert rather than queueing behind it")
        XCTAssertEqual(visibleConsoleLines(vm.log).count, 1)
    }

    // MARK: - The two modes agree

    /// Both modes route through the same coordinator, and the wording they hand
    /// it is byte-identical today. Pinned so a change to one is noticed as a
    /// divergence from the other rather than shipping as a silent asymmetry.
    func testBothModesReportTheSameSkipTheSameWay() throws {
        let waxOn = ContentViewModel()
        let waxOff = DeliveryViewModel()
        defer { waxOn.fileQueue.clearAll(); waxOff.fileQueue.clearAll() }

        waxOn.addFiles([try makeMixedFolder("mixed-on")])
        waxOff.addFiles([try makeMixedFolder("mixed-off")])

        XCTAssertEqual(visibleConsoleLines(waxOn.log), visibleConsoleLines(waxOff.log))
        XCTAssertNil(waxOn.alertMessage)
        XCTAssertNil(waxOff.alertMessage)
    }

    /// And the alert case likewise — the modes should not disagree about when
    /// an add is worth interrupting for.
    func testBothModesAlertOnTheSameEmptyAdd() throws {
        let waxOn = ContentViewModel()
        let waxOff = DeliveryViewModel()
        let folder = try makeFolder("shared-no-audio", containing: ["notes.txt"])

        waxOn.addFiles([folder])
        waxOff.addFiles([folder])

        XCTAssertEqual(waxOn.alertMessage, waxOff.alertMessage)
        XCTAssertNotNil(waxOn.alertMessage)
    }
}
