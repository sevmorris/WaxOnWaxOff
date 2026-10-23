import XCTest
@testable import WaxOnWaxOff

/// What happens to a change made after choosing a preset, and to the output
/// folder when a preset is chosen or saved.
///
/// A relaunch is a second view model over the same store. Each test passes a
/// scratch store of its own, since changing a setting saves it.
@MainActor
final class PresetEditsTests: XCTestCase {
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

    private var editPrep: WaxOnPreset {
        WaxOnPreset.builtIn.first { $0.name == "Edit Prep" }!
    }

    private var podcastLoud: WaxOffPreset {
        WaxOffPreset.builtIn.first { $0.name == "Podcast Loud" }!
    }

    // MARK: - WaxOn

    /// The case that lost work: choose a preset, change a setting, relaunch.
    /// The launch used to apply the preset again over the change.
    func testWaxOnAChangeAfterAPresetSurvivesARelaunch() {
        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.applyPreset(editPrep)
        vm.settings.loudnormTarget = -24
        vm.settings.outputDirectoryPath = "/Shows/Episode"

        let relaunched = ContentViewModel(defaults: scratch.defaults)
        XCTAssertEqual(relaunched.settings.loudnormTarget, -24)
        XCTAssertEqual(relaunched.settings.outputDirectoryPath, "/Shows/Episode")
        XCTAssertEqual(relaunched.presetStore.selectedPresetID, editPrep.id)
        XCTAssertTrue(relaunched.presetIsModified)
    }

    func testWaxOnChoosingThePresetAgainGoesBackToIt() {
        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.applyPreset(editPrep)
        XCTAssertFalse(vm.presetIsModified)
        vm.settings.highPassEnabled = false
        XCTAssertTrue(vm.presetIsModified)

        vm.applyPreset(editPrep)
        XCTAssertEqual(vm.settings, editPrep.settings)
        XCTAssertFalse(vm.presetIsModified)
    }

    func testWaxOnNoPresetIsNeverModified() {
        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.settings.loudnormEnabled.toggle()
        XCTAssertNil(vm.presetStore.selectedPresetID)
        XCTAssertFalse(vm.presetIsModified)
    }

    func testWaxOnChoosingAPresetKeepsTheOutputFolder() {
        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.settings.outputDirectoryPath = "/Shows/Episode"
        vm.applyPreset(editPrep)
        XCTAssertEqual(vm.settings.outputDirectoryPath, "/Shows/Episode")
        XCTAssertEqual(vm.settings.loudnormTarget, editPrep.settings.loudnormTarget)
    }

    func testWaxOnChoosingAFolderDoesNotModifyThePreset() {
        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.applyPreset(editPrep)
        vm.settings.outputDirectoryPath = "/Shows/Episode"
        XCTAssertFalse(vm.presetIsModified)
    }

    func testWaxOnAPresetIsSavedAndUpdatedWithoutTheFolder() throws {
        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.settings.outputDirectoryPath = "/Shows/Episode"
        vm.saveCurrentAsPreset(name: "Mine")
        let saved = try XCTUnwrap(vm.presetStore.presets.first)
        XCTAssertNil(saved.settings.outputDirectoryPath)

        vm.settings.outputDirectoryPath = "/Shows/Other"
        vm.presetStore.updatePreset(id: saved.id, name: nil, settings: vm.settings)
        XCTAssertNil(try XCTUnwrap(vm.presetStore.presets.first).settings.outputDirectoryPath)
    }

    /// Presets saved before this change can still hold a folder. Choosing one
    /// keeps the current folder, and the old one does not count as a change.
    func testWaxOnAnOlderPresetsFolderIsIgnored() throws {
        var withFolder = WaxOnSettings()
        withFolder.outputDirectoryPath = "/Old/Folder"
        let old = WaxOnPreset(name: "Old", settings: withFolder)
        let data = try JSONEncoder().encode([old])
        scratch.defaults.set(data, forKey: "WaxOnUserPresets")

        let vm = ContentViewModel(defaults: scratch.defaults)
        vm.settings.outputDirectoryPath = "/Shows/Episode"
        vm.applyPreset(try XCTUnwrap(vm.presetStore.presets.first))
        XCTAssertEqual(vm.settings.outputDirectoryPath, "/Shows/Episode")
        XCTAssertFalse(vm.presetIsModified)
    }

    // MARK: - WaxOff

    func testWaxOffAChangeAfterAPresetSurvivesARelaunch() {
        let vm = DeliveryViewModel(defaults: scratch.defaults)
        vm.applyPreset(podcastLoud)
        vm.settings.mp3Bitrate = 192
        vm.settings.outputDirectoryPath = "/Shows/Delivery"

        let relaunched = DeliveryViewModel(defaults: scratch.defaults)
        XCTAssertEqual(relaunched.settings.mp3Bitrate, 192)
        XCTAssertEqual(relaunched.settings.outputDirectoryPath, "/Shows/Delivery")
        XCTAssertEqual(relaunched.presetStore.selectedPresetID, podcastLoud.id)
        XCTAssertTrue(relaunched.presetIsModified)
    }

    func testWaxOffChoosingThePresetAgainGoesBackToIt() {
        let vm = DeliveryViewModel(defaults: scratch.defaults)
        vm.applyPreset(podcastLoud)
        vm.settings.targetLUFS = -19
        XCTAssertTrue(vm.presetIsModified)

        vm.applyPreset(podcastLoud)
        XCTAssertEqual(vm.settings, podcastLoud.settings)
        XCTAssertFalse(vm.presetIsModified)
    }

    func testWaxOffChoosingAPresetKeepsTheOutputFolder() {
        let vm = DeliveryViewModel(defaults: scratch.defaults)
        vm.settings.outputDirectoryPath = "/Shows/Delivery"
        vm.applyPreset(podcastLoud)
        XCTAssertEqual(vm.settings.outputDirectoryPath, "/Shows/Delivery")
        XCTAssertFalse(vm.presetIsModified)
    }

    func testWaxOffAPresetIsSavedAndUpdatedWithoutTheFolder() throws {
        let vm = DeliveryViewModel(defaults: scratch.defaults)
        vm.settings.outputDirectoryPath = "/Shows/Delivery"
        vm.saveCurrentAsPreset(name: "Mine")
        let saved = try XCTUnwrap(vm.presetStore.presets.first)
        XCTAssertNil(saved.settings.outputDirectoryPath)

        vm.presetStore.updatePreset(id: saved.id, name: nil, settings: vm.settings)
        XCTAssertNil(try XCTUnwrap(vm.presetStore.presets.first).settings.outputDirectoryPath)
    }
}
