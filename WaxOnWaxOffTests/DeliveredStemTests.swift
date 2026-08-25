import XCTest
@testable import WaxOnWaxOff

/// `DeliveryProcessor.deliveredStem(forSource:targetLUFS:)` is the name the
/// metadata sheet shows as the Episode Title placeholder and the name delivery
/// actually writes the file under. Those were two separate computations once —
/// the sheet showed the source stem while delivery wrote `stem-lev-16LUFS` —
/// so a user who left the field empty expecting `interview` got
/// `interview-lev-16LUFS` in the ID3 title.
///
/// These tests exist to stop that recurring. They do not check the helper
/// against a second copy of the format string written here; they drive the
/// real `OutputAllocator` that `DeliveryProcessor.run` delivers through, so
/// changing the allocator's naming without changing the helper (or the other
/// way round) fails.
final class DeliveredStemTests: XCTestCase {

    private let outputDir = URL(fileURLWithPath: "/tmp/waxoff-delivered-stem", isDirectory: true)

    /// The helper and the allocator must agree — that agreement IS the fix.
    private func assertAgreement(
        source: URL,
        targetLUFS: Double,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let stem = DeliveryProcessor.deliveredStem(forSource: source, targetLUFS: targetLUFS)
        XCTAssertEqual(stem, expected, "the placeholder text changed", file: file, line: line)

        // A fresh allocator per call: the first allocation of a name is the
        // uncontended one, which is what the placeholder predicts.
        let allocated = DeliveryProcessor
            .outputAllocator(targetLUFS: targetLUFS)
            .allocate(for: source, in: outputDir)
        XCTAssertEqual(
            allocated.deletingPathExtension().lastPathComponent, stem,
            "the delivered stem and the placeholder disagree",
            file: file, line: line
        )
        XCTAssertEqual(allocated.lastPathComponent, "\(expected).wav", file: file, line: line)
    }

    func testIntegerTarget() {
        assertAgreement(
            source: URL(fileURLWithPath: "/Users/someone/Audio/interview.wav"),
            targetLUFS: -16,
            expected: "interview-lev-16LUFS"
        )
    }

    /// A fractional target renders with one decimal, so the placeholder has to
    /// as well: `-16.5` must not show as `-16` or `-17`.
    func testFractionalTarget() {
        assertAgreement(
            source: URL(fileURLWithPath: "/Users/someone/Audio/interview.aiff"),
            targetLUFS: -16.5,
            expected: "interview-lev-16.5LUFS"
        )
    }

    /// The two LUFS presets either side of the podcast default, to catch a
    /// sign or rounding change in `formatNumber`.
    func testOtherTargets() {
        let source = URL(fileURLWithPath: "/Users/someone/Audio/interview.wav")
        assertAgreement(source: source, targetLUFS: -14, expected: "interview-lev-14LUFS")
        assertAgreement(source: source, targetLUFS: -18, expected: "interview-lev-18LUFS")
        assertAgreement(source: source, targetLUFS: -23, expected: "interview-lev-23LUFS")
    }

    /// Dots and spaces are ordinary in a mix file's name. Only the last
    /// extension comes off, and nothing else about the name is rewritten — so
    /// the placeholder must show the same thing.
    func testSourceNameWithDotsAndSpaces() {
        assertAgreement(
            source: URL(fileURLWithPath: "/Users/someone/Audio/Ep 12 — Guest v2.final mix.wav"),
            targetLUFS: -16,
            expected: "Ep 12 — Guest v2.final mix-lev-16LUFS"
        )
    }

    func testSourceWithNoExtension() {
        assertAgreement(
            source: URL(fileURLWithPath: "/Users/someone/Audio/interview"),
            targetLUFS: -16,
            expected: "interview-lev-16LUFS"
        )
    }

    /// The documented limit of the helper: it predicts the uncontended name.
    /// Two different sources whose names collide inside one batch get a
    /// disambiguating tag from the allocator, and the second one's real stem is
    /// therefore not what the placeholder said. That is the one case the doc
    /// comment calls out, and it stays a one-line divergence rather than the
    /// every-file divergence this change removed.
    func testCollidingSecondInputDivergesOnlyByTheAllocatorTag() {
        let allocator = DeliveryProcessor.outputAllocator(targetLUFS: -16)
        let first = URL(fileURLWithPath: "/Users/someone/Monday/interview.wav")
        let second = URL(fileURLWithPath: "/Users/someone/Tuesday/interview.wav")

        let firstStem = allocator.allocate(for: first, in: outputDir)
            .deletingPathExtension().lastPathComponent
        let secondStem = allocator.allocate(for: second, in: outputDir)
            .deletingPathExtension().lastPathComponent

        XCTAssertEqual(firstStem, DeliveryProcessor.deliveredStem(forSource: first, targetLUFS: -16))
        XCTAssertNotEqual(secondStem, firstStem, "the allocator must not hand out the same path twice")
        XCTAssertTrue(secondStem.hasPrefix("interview-"))
        XCTAssertTrue(secondStem.hasSuffix("-lev-16LUFS"))
    }

    /// The placeholder is a prediction of the delivered stem, and the delivered
    /// stem is what `mp3Arguments` writes into the ID3 title when the user
    /// leaves Episode Title empty. Pinned here because the placeholder is only
    /// truthful while that fallback holds.
    func testEmptyEpisodeTitleIsTaggedWithTheDeliveredStem() {
        let source = URL(fileURLWithPath: "/Users/someone/Audio/interview.wav")
        let stem = DeliveryProcessor.deliveredStem(forSource: source, targetLUFS: -16)

        let args = DeliveryProcessor.mp3Arguments(
            input: outputDir.appendingPathComponent("\(stem).wav"),
            output: outputDir.appendingPathComponent("\(stem).mp3"),
            title: stem,
            metadata: EpisodeMetadata(),
            chaptersFile: nil,
            settings: WaxOffSettings(),
            outputChannelCount: 2
        )

        XCTAssertTrue(args.contains("title=\(stem)"),
                      "an untagged file must still deliver with the stem as its title: \(args)")
    }
}
