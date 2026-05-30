import XCTest
@testable import WaxOnWaxOff

@MainActor
final class WaxOffSettingsTests: XCTestCase {
    private let storageKey = "WaxOffSettings"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        super.tearDown()
    }

    func testLoadMigratesLegacyLRA() throws {
        var settings = WaxOffSettings()
        settings.lra = 11.0
        let data = try JSONEncoder().encode(settings)
        UserDefaults.standard.set(data, forKey: storageKey)

        XCTAssertEqual(WaxOffSettings.load().lra, 9.0)
    }

    func testLoadPreservesCustomLRA() throws {
        var settings = WaxOffSettings()
        settings.lra = 7.0
        let data = try JSONEncoder().encode(settings)
        UserDefaults.standard.set(data, forKey: storageKey)

        XCTAssertEqual(WaxOffSettings.load().lra, 7.0)
    }
}
