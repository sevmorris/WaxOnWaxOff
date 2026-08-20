import XCTest
@testable import WaxOnWaxOff

/// The labels on the detail pane's output switcher.
///
/// Pure string math over real output names, so it can be pinned exactly. The
/// prefix/suffix index arithmetic is the kind that silently goes off by one,
/// and a wrong result is visible in the UI rather than caught by the compiler.
final class OutputFileLabelTests: XCTestCase {
    private func labels(_ names: [String]) -> [String] {
        OutputFile.labels(for: names.map { URL(fileURLWithPath: "/out/\($0)") })
    }

    /// A single-output job needs no label — the switcher isn't shown.
    func testSingleOutputHasNoLabel() {
        XCTAssertEqual(labels(["interview-44kwaxon.wav"]), [""])
    }

    /// WaxOn Split L/R: same extension, so the labels come from the stem.
    func testSplitChannelsLabelByChannel() {
        XCTAssertEqual(labels(["interview-L-44kwaxon.wav", "interview-R-44kwaxon.wav"]), ["L", "R"])
    }

    /// WaxOff Both: same stem, so the labels come from the extension.
    func testDualFormatLabelsByExtension() {
        XCTAssertEqual(labels(["show-lev-18LUFS.wav", "show-lev-18LUFS.mp3"]), ["WAV", "MP3"])
    }

    /// A name-collision render tags each output differently; the leading
    /// component of the diff is still the part that tells them apart.
    func testDisambiguatedSplitStillLabelsByChannel() {
        XCTAssertEqual(labels(["a-L-9f3c-44kwaxon.wav", "a-R-77ab-44kwaxon.wav"]), ["L", "R"])
    }

    /// Nothing distinguishing in the names: fall back to ordinals rather than
    /// returning duplicate or empty labels.
    func testIndistinguishableNamesFallBackToOrdinals() {
        XCTAssertEqual(labels(["same.wav", "same.wav"]), ["1", "2"])
    }
}
