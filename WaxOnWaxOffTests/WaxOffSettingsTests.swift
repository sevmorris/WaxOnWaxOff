import XCTest
@testable import WaxOnWaxOff

/// These used to write their blobs under WaxOffSettings in
/// `UserDefaults.standard` — which, with the tests hosted by the app, is the
/// developer's real domain — and tearDown then removed that key, deleting the
/// developer's WaxOff settings on every run. They load from a suite of their
/// own now.
@MainActor
final class WaxOffSettingsTests: XCTestCase {
    /// The key the app has always used; renaming it would lose everyone's settings.
    private let storageKey = "WaxOffSettings"
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

    func testLoadMigratesLegacyLRA() throws {
        var settings = WaxOffSettings()
        settings.lra = 11.0
        let data = try JSONEncoder().encode(settings)
        scratch.defaults.set(data, forKey: storageKey)

        XCTAssertEqual(WaxOffSettings.load(from: scratch.defaults).lra, 9.0)
    }

    func testLoadPreservesCustomLRA() throws {
        var settings = WaxOffSettings()
        settings.lra = 7.0
        let data = try JSONEncoder().encode(settings)
        scratch.defaults.set(data, forKey: storageKey)

        XCTAssertEqual(WaxOffSettings.load(from: scratch.defaults).lra, 7.0)
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
