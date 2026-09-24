import XCTest

/// A defaults suite of a test's own, for code that loads or saves settings.
///
/// The tests run inside the app, so `UserDefaults.standard` here is the
/// developer's real settings. A test that loads or saves passes one of these
/// instead, and removes it in tearDown.
///
/// The suite is named by a path in a temporary folder. A suite named like a
/// bundle identifier lives in ~/Library/Preferences, and removing its domain
/// empties the file but leaves it there, matching the io.github.sevmorris.*
/// pattern the App Preferences source backs up. Deleting the file in tearDown
/// does not hold: cfprefsd writes it back after the test has finished.
/// Deleting a folder of our own does.
final class ScratchDefaults {
    let defaults: UserDefaults
    private let folder: URL
    private let suiteName: String

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxon-defaults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = folder.appendingPathComponent("defaults").path
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }
}
