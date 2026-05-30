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

    func testLooksLikeWaxOffDeliveryMatchesOutputNaming() {
        let delivered = URL(fileURLWithPath: "/tmp/episode-lev-18LUFS.wav")
        let raw = URL(fileURLWithPath: "/tmp/interview.wav")
        let waxon = URL(fileURLWithPath: "/tmp/guest-44kwaxon.wav")

        XCTAssertTrue(OutputNaming.looksLikeWaxOffDelivery(delivered))
        XCTAssertFalse(OutputNaming.looksLikeWaxOffDelivery(raw))
        XCTAssertFalse(OutputNaming.looksLikeWaxOffDelivery(waxon))
    }

    func testLooksLikeWaxOnPrep() {
        XCTAssertTrue(OutputNaming.looksLikeWaxOnPrep(URL(fileURLWithPath: "/tmp/a-48kwaxon.wav")))
        XCTAssertFalse(OutputNaming.looksLikeWaxOnPrep(URL(fileURLWithPath: "/tmp/a-lev-18LUFS.wav")))
    }
}
