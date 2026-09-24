import XCTest
@testable import WaxOnWaxOff

/// Everything the app keeps in defaults goes to the store it is given, and a
/// test run never gets the real one.
///
/// The tests run inside the app, so `UserDefaults.standard` here is the
/// developer's real settings. Each test passes a suite of its own, removed in
/// tearDown; what forgets to falls through to `UserDefaults.app`, which in a
/// test run is a scratch suite.
@MainActor
final class SettingsStoreTests: XCTestCase {
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

    func testATestRunDoesNotGetTheRealDefaults() {
        XCTAssertTrue(AppLauncher.isHostingTests)
        XCTAssertFalse(UserDefaults.app === UserDefaults.standard)
    }

    func testWaxOnSettingsRoundTrip() {
        var settings = WaxOnSettings()
        settings.sampleRate = .s48000
        settings.outputChannels = .splitLR
        settings.save(to: scratch.defaults)
        XCTAssertEqual(WaxOnSettings.load(from: scratch.defaults), settings)
    }

    func testWaxOffSettingsRoundTrip() {
        var settings = WaxOffSettings()
        settings.targetLUFS = -16
        settings.outputMode = .mp3
        settings.save(to: scratch.defaults)
        XCTAssertEqual(WaxOffSettings.load(from: scratch.defaults), settings)
    }

    func testTheLastModeComesBackFromTheSameStore() {
        AppState(defaults: scratch.defaults).mode = .waxOff
        XCTAssertEqual(AppState(defaults: scratch.defaults).mode, .waxOff)
    }

    func testAPresetAndItsSelectionComeBackFromTheSameStore() {
        var settings = WaxOnSettings()
        settings.loudnormEnabled = true
        let preset = WaxOnPreset(name: "Scratch", settings: settings)
        WaxOnPresetStore(defaults: scratch.defaults).savePreset(preset)

        let reloaded = WaxOnPresetStore(defaults: scratch.defaults)
        XCTAssertEqual(reloaded.presets, [preset])
        XCTAssertEqual(reloaded.selectedPresetID, preset.id)
    }

    /// The path that reached the real settings at every launch and in every
    /// test that built a view model: a selected preset is applied on init, and
    /// applying it saves.
    func testTheViewModelAppliesAndSavesTheSelectedPresetInItsOwnStore() {
        var settings = WaxOffSettings()
        settings.targetLUFS = -14
        settings.outputMode = .wav
        let preset = WaxOffPreset(name: "Scratch", settings: settings)
        WaxOffPresetStore(defaults: scratch.defaults).savePreset(preset)

        let vm = DeliveryViewModel(defaults: scratch.defaults)
        XCTAssertEqual(vm.settings, settings)

        vm.settings.mp3Bitrate = 192
        XCTAssertEqual(WaxOffSettings.load(from: scratch.defaults), vm.settings)
    }
}
