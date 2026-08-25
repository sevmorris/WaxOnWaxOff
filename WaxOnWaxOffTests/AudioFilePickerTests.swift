import UniformTypeIdentifiers
import XCTest
@testable import WaxOnWaxOff

/// The Add button's open-panel filter.
///
/// The property that matters is coverage, not the exact list: the panel must
/// offer everything `FileQueueCoordinator.addFiles` would accept from a drop.
/// Anything narrower is a format that silently cannot be picked while
/// drag-and-drop still takes it, with no message anywhere saying so.
///
/// `UTType(filenameExtension:)` is the quiet part. It does not answer nil for an
/// extension the system has no declaration for — it answers an *undeclared,
/// dynamic* type, which matches no file in a panel. `testDynamicTypesCountAsUnresolved`
/// pins that this is treated as a failure rather than as a usable type.
final class AudioFilePickerTests: XCTestCase {

    private let defaults = FileQueueCoordinator.defaultValidExtensions

    // MARK: - Coverage

    /// Every extension the file queue accepts is reachable in the panel, either
    /// through its own declared type or through a supertype the fallback added.
    func testEveryAcceptedExtensionIsCoveredByAPanelType() {
        let types = AudioFilePicker.contentTypes(for: defaults)

        for ext in defaults {
            guard let type = UTType(filenameExtension: ext), type.isDeclared else {
                // Unresolvable here, so the widened supertypes are what has to
                // cover it. Asserted in full by testUnresolvedExtensionWidens…;
                // this only records that the fallback did fire.
                XCTAssertTrue(
                    types.contains(.audio) && types.contains(.movie),
                    "\(ext) does not resolve on this system, so the panel must have widened to public.audio/public.movie"
                )
                continue
            }
            XCTAssertTrue(
                types.contains { type == $0 || type.conforms(to: $0) },
                "\(ext) (\(type.identifier)) is accepted by addFiles but no panel type matches it"
            )
        }
    }

    /// A folder is a legitimate thing to hand `addFiles` — it expands one — so
    /// the panel filter has to admit folders as well as `canChooseDirectories`.
    func testFolderIsAlwaysAllowed() {
        XCTAssertTrue(AudioFilePicker.contentTypes(for: defaults).contains(.folder))
        XCTAssertTrue(AudioFilePicker.contentTypes(for: []).contains(.folder))
        XCTAssertTrue(AudioFilePicker.contentTypes(for: ["wav"]).contains(.folder))
    }

    // MARK: - The quiet failure

    /// The case the whole `isDeclared` check exists for. An unknown extension
    /// yields a dynamic type that is non-nil and useless; if it were kept as-is
    /// the panel would show a filter entry matching nothing.
    func testDynamicTypesCountAsUnresolved() {
        let bogus = UTType(filenameExtension: "zzqqnotarealextension")
        XCTAssertNotNil(bogus, "precondition: an unknown extension yields a type rather than nil")
        XCTAssertFalse(bogus?.isDeclared ?? true, "precondition: that type is undeclared")

        let types = AudioFilePicker.contentTypes(for: ["zzqqnotarealextension"])
        XCTAssertFalse(types.contains { $0.isDeclared == false })
        XCTAssertTrue(types.contains(.audio))
        XCTAssertTrue(types.contains(.movie))
    }

    /// One bad extension widens the whole list rather than dropping that one
    /// format — the good types stay, and the supertypes join them.
    func testUnresolvedExtensionWidensWithoutLosingTheResolvedOnes() {
        let types = AudioFilePicker.contentTypes(for: ["wav", "zzqqnotarealextension"])
        XCTAssertTrue(types.contains(.wav))
        XCTAssertTrue(types.contains(.audio))
        XCTAssertTrue(types.contains(.movie))
    }

    /// An empty set is not a reason to hand the panel nothing but folders: an
    /// empty `allowedContentTypes` would leave every file enabled anyway, so the
    /// honest answer is the widened one.
    func testEmptyExtensionSetWidens() {
        let types = AudioFilePicker.contentTypes(for: [])
        XCTAssertTrue(types.contains(.audio))
        XCTAssertTrue(types.contains(.movie))
    }

    // MARK: - Shape of the list

    /// `aif` and `aiff` both answer `public.aiff-audio`. A repeated entry in
    /// `allowedContentTypes` is not fatal, but it is a duplicated line in the
    /// panel's own format menu.
    func testDuplicateTypesAreCollapsed() {
        let types = AudioFilePicker.contentTypes(for: ["aif", "aiff"])
        XCTAssertEqual(types, [.aiff, .folder])
    }

    func testNoDuplicateIdentifiers() {
        let types = AudioFilePicker.contentTypes(for: defaults)
        XCTAssertEqual(Set(types.map(\.identifier)).count, types.count)
    }

    /// The input is a `Set`, whose iteration order varies per process. Without
    /// the sort the panel's format menu would reorder itself between launches.
    func testOrderIsStable() {
        XCTAssertEqual(
            AudioFilePicker.contentTypes(for: defaults),
            AudioFilePicker.contentTypes(for: defaults)
        )
        XCTAssertEqual(
            AudioFilePicker.contentTypes(for: ["mp3", "wav", "flac"]),
            AudioFilePicker.contentTypes(for: ["flac", "mp3", "wav"])
        )
    }

    /// Not an assertion about correctness — a record of what this machine
    /// resolves, so a future macOS that stops declaring one of these shows up as
    /// a named failure here rather than as a format quietly missing from the
    /// picker. The fallback keeps the app correct either way.
    func testAllElevenDefaultsResolveOnThisSystem() {
        for ext in defaults.sorted() {
            let type = UTType(filenameExtension: ext)
            XCTAssertEqual(
                type?.isDeclared, true,
                "\(ext) no longer resolves to a declared type — the panel now falls back to the audio/movie supertypes for every format"
            )
        }
    }
}
