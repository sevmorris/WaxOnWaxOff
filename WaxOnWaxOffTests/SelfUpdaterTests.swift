import XCTest
@testable import WaxOnWaxOff

/// Everything here works on throwaway apps in a temporary folder, signed ad hoc,
/// so a requirement naming the test's identifier stands in for the Developer ID.
/// The running app and anything installed are never touched.
final class SelfUpdaterTests: XCTestCase {

    private static let bundleID = "io.github.sevmorris.SelfUpdaterTests.Fake"
    private static let requirement = "identifier \"\(bundleID)\""

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // The not-writable test takes write permission away from a folder.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Helpers

    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A signed bundle around a copy of /usr/bin/true, which is universal.
    private func makeApp(at url: URL, version: String = "2.0.0lr", bundleID: String = SelfUpdaterTests.bundleID,
                         minimumMacOS: String = "15.0", sign: Bool = true) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: macOS.appendingPathComponent("Fake"))
        let info: [String: Any] = [
            "CFBundleExecutable": "Fake",
            "CFBundleIdentifier": bundleID,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "LSMinimumSystemVersion": minimumMacOS,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if sign {
            XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", url.path]), 0)
        }
        return url
    }

    private func expected(installed: String = "1.0.0lr",
                          os: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                          architecture: Int = SelfUpdater.runningArchitecture) -> SelfUpdater.Expected {
        SelfUpdater.Expected(bundleID: Self.bundleID, installedVersion: installed,
                             appRequirement: Self.requirement,
                             diskImageRequirement: "identifier \"update\"",
                             os: os, architecture: architecture)
    }

    private func assertVet(_ app: URL, _ expected: SelfUpdater.Expected, throws failure: SelfUpdater.Failure,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SelfUpdater.vet(app, against: expected), file: file, line: line) {
            XCTAssertEqual($0 as? SelfUpdater.Failure, failure, file: file, line: line)
        }
    }

    // MARK: - Signatures

    /// Only a Developer ID from this team passes, so an ad hoc build does not.
    func testAnAdHocAppDoesNotMeetTheReleaseRequirement() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"))
        XCTAssertTrue(SelfUpdater.isSigned(app, requirement: Self.requirement))
        XCTAssertFalse(SelfUpdater.isSigned(app, requirement: SelfUpdater.appRequirement(bundleID: Self.bundleID)))
    }

    func testTheReleaseRequirementParsesAndNamesTheApp() {
        XCTAssertTrue(SelfUpdater.appRequirement(bundleID: "a.b").hasPrefix("identifier \"a.b\" and anchor apple generic"))
        var parsed: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(SelfUpdater.appRequirement(bundleID: "a.b") as CFString, [], &parsed),
                       errSecSuccess)
    }

    func testAnAppChangedAfterSigningFails() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"))
        let info = app.appendingPathComponent("Contents/Info.plist")
        try Data("<plist/>".utf8).write(to: info)
        XCTAssertFalse(SelfUpdater.isSigned(app, requirement: Self.requirement))
    }

    func testAnUnsignedAppFails() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"), sign: false)
        XCTAssertFalse(SelfUpdater.isSigned(app, requirement: Self.requirement))
    }

    // MARK: - Vetting

    func testAcceptsANewerAppThatRunsHere() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"), version: "2.0.0lr")
        XCTAssertNoThrow(try SelfUpdater.vet(app, against: expected()))
    }

    func testRefusesAnotherAppWithAValidSignature() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"), bundleID: "io.github.sevmorris.Other")
        assertVet(app, expected(), throws: .untrusted)
    }

    /// The same version, and a downgrade, are both refused. Numeric, so 2.10 is
    /// newer than 2.9, and the flavour suffix plays no part.
    func testRefusesAnythingNotNewer() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"), version: "2.9.0lr")
        assertVet(app, expected(installed: "2.9.0lr"), throws: .notNewer)
        assertVet(app, expected(installed: "2.9.0cr"), throws: .notNewer)
        assertVet(app, expected(installed: "2.10.0lr"), throws: .notNewer)
        XCTAssertNoThrow(try SelfUpdater.vet(app, against: expected(installed: "2.8.9lr")))
    }

    func testRefusesAnAppThisMacOSCannotOpen() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"), minimumMacOS: "27.1")
        let older = OperatingSystemVersion(majorVersion: 26, minorVersion: 7, patchVersion: 0)
        assertVet(app, expected(os: older), throws: .needsNewerMacOS("27.1"))
    }

    func testRefusesAnAppWithoutThisProcessorsSlice() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"))
        assertVet(app, expected(architecture: NSBundleExecutableArchitecturePPC), throws: .wrongArchitecture)
    }

    func testFindsTheOneAppOnAVolumeWhateverItsName() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Any Name.app"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Applications"),
                                                   withDestinationURL: URL(fileURLWithPath: "/Applications"))
        XCTAssertEqual(try SelfUpdater.app(in: folder).lastPathComponent, app.lastPathComponent)

        _ = try makeApp(at: folder.appendingPathComponent("Second.app"))
        XCTAssertThrowsError(try SelfUpdater.app(in: folder))
    }

    func testComparesOnlyTheNumericPartOfAVersion() {
        XCTAssertEqual(SelfUpdater.numericVersion("2.8.0lr"), "2.8.0")
        XCTAssertEqual(SelfUpdater.numericVersion("2.8.0"), "2.8.0")
        XCTAssertEqual(SelfUpdater.numericVersion("1.8"), "1.8")
    }

    // MARK: - Whether this copy can update

    func testADevelopmentBuildKeepsTheDownloadButton() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"))
        let release = SelfUpdater.appRequirement(bundleID: Self.bundleID)
        XCTAssertEqual(SelfUpdater.obstacle(for: app, requirement: release), .notARelease)
    }

    func testAWritableSignedCopyHasNoObstacle() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"))
        XCTAssertNil(SelfUpdater.obstacle(for: app, requirement: Self.requirement))
    }

    func testACopyInAReadOnlyFolderCannotUpdate() throws {
        let app = try makeApp(at: folder.appendingPathComponent("Fake.app"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertEqual(SelfUpdater.obstacle(for: app, requirement: Self.requirement), .notWritable)
    }

    func testRecognizesATranslocatedPath() {
        XCTAssertTrue(SelfUpdater.isTranslocated(URL(fileURLWithPath: "/private/var/folders/xx/T/AppTranslocation/ABC/d/DoublEnder.app")))
        XCTAssertFalse(SelfUpdater.isTranslocated(URL(fileURLWithPath: "/Applications/DoublEnder.app")))
    }

    // MARK: - Installing

    func testSwapExchangesTheTwoApps() throws {
        let installed = try makeApp(at: folder.appendingPathComponent("Installed.app"), version: "1.0.0lr")
        let staged = try makeApp(at: folder.appendingPathComponent("Staged.app"), version: "2.0.0lr")

        try SelfUpdater.swap(staged: staged, into: installed)

        func version(_ url: URL) throws -> String? {
            let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            return info?["CFBundleShortVersionString"] as? String
        }
        XCTAssertEqual(try version(installed), "2.0.0lr")
        XCTAssertEqual(try version(staged), "1.0.0lr")
        XCTAssertTrue(SelfUpdater.isSigned(installed, requirement: Self.requirement))
    }

    /// A failed swap has to leave the only copy of the app where it was.
    func testAFailedSwapLeavesTheInstalledAppAlone() throws {
        let installed = try makeApp(at: folder.appendingPathComponent("Installed.app"))
        let missing = folder.appendingPathComponent("Missing.app")

        XCTAssertThrowsError(try SelfUpdater.swap(staged: missing, into: installed))
        XCTAssertTrue(SelfUpdater.isSigned(installed, requirement: Self.requirement))
    }

    func testDiscardRemovesTheStagedCopyAndItsFolder() throws {
        let holder = folder.appendingPathComponent("holder", isDirectory: true)
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
        let staged = try makeApp(at: holder.appendingPathComponent("Fake.app"))

        SelfUpdater.discard(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: holder.path))
    }

    // MARK: - A disk image, start to finish

    /// A signed image built the way a release is laid out. hdiutil is known to
    /// fail now and then on a busy machine, and building the image is not what
    /// is on trial here, so a failure to build one skips rather than fails.
    private func makeDiskImage(holding app: URL, sign: Bool = true) throws -> URL {
        let source = app.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Applications"),
                                                   withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let scratch = folder.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let dmg = scratch.appendingPathComponent("update.dmg")
        guard try run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-format", "UDZO",
                                           "-srcfolder", source.path, dmg.path]) == 0 else {
            throw XCTSkip("hdiutil could not build a disk image here")
        }
        if sign {
            XCTAssertEqual(try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "update", dmg.path]), 0)
        }
        return dmg
    }

    func testStagesAVettedCopyFromASignedImageAndDetachesIt() throws {
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try makeApp(at: source.appendingPathComponent("Fake.app"))
        let dmg = try makeDiskImage(holding: source.appendingPathComponent("Fake.app"))
        let installed = try makeApp(at: folder.appendingPathComponent("Installed.app"), version: "1.0.0lr")

        let staged = try SelfUpdater.stage(diskImage: dmg, replacing: installed, expected: expected())
        defer { SelfUpdater.discard(staged) }

        XCTAssertEqual(staged.lastPathComponent, "Installed.app", "takes the name of the copy it replaces")
        XCTAssertTrue(SelfUpdater.isSigned(staged, requirement: Self.requirement))
        // The mount point is empty again once the image is detached.
        let mountPoint = dmg.deletingLastPathComponent().appendingPathComponent("mount")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mountPoint.path), [])
    }

    func testRefusesToMountAnUnsignedImage() throws {
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try makeApp(at: source.appendingPathComponent("Fake.app"))
        let dmg = try makeDiskImage(holding: source.appendingPathComponent("Fake.app"), sign: false)
        let installed = try makeApp(at: folder.appendingPathComponent("Installed.app"), version: "1.0.0lr")

        XCTAssertThrowsError(try SelfUpdater.stage(diskImage: dmg, replacing: installed, expected: expected())) {
            XCTAssertEqual($0 as? SelfUpdater.Failure, .untrusted)
        }
        // It stopped before the mount point was made.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmg.deletingLastPathComponent().appendingPathComponent("mount").path))
    }
}
