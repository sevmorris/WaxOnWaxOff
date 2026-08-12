import XCTest
@testable import WaxOnWaxOff

/// Covers `ArtworkInspector`, which reads cover-art dimensions and thumbnails
/// straight from the image header. Fixtures are generated with the bundled
/// ffmpeg so no binary images are committed.
final class ArtworkInspectorTests: XCTestCase {

    func testNoteFlagsNonSquareImage() throws {
        let url = try makeImage(width: 1400, height: 900, name: "wide.png")
        XCTAssertEqual(ArtworkInspector.note(for: url), "1400×900 — not square")
    }

    func testNoteIsPlainSizeForValidCover() throws {
        let url = try makeImage(width: 1400, height: 1400, name: "valid.png")
        XCTAssertEqual(ArtworkInspector.note(for: url), "1400×1400")
    }

    func testNoteFlagsUndersizedSquare() throws {
        let url = try makeImage(width: 600, height: 600, name: "small.png")
        XCTAssertEqual(
            ArtworkInspector.note(for: url),
            "600×600 — below Apple Podcasts' 1400 px minimum"
        )
    }

    func testNoteFlagsOversizedSquare() throws {
        let url = try makeImage(width: 3200, height: 3200, name: "big.png")
        XCTAssertEqual(
            ArtworkInspector.note(for: url),
            "3200×3200 — above Apple Podcasts' 3000 px maximum"
        )
    }

    /// The 1400 and 3000 px bounds are inclusive — a cover exactly on either
    /// edge is what Apple asks for, not something to warn about.
    func testNoteAcceptsBothBoundsInclusively() throws {
        let low = try makeImage(width: 1400, height: 1400, name: "low-bound.png")
        let high = try makeImage(width: 3000, height: 3000, name: "high-bound.png")
        XCTAssertEqual(ArtworkInspector.note(for: low), "1400×1400")
        XCTAssertEqual(ArtworkInspector.note(for: high), "3000×3000")
    }

    /// Artwork can vanish between tagging and reopening the sheet. The note is
    /// the only place that reads it, so it has to survive a missing file.
    func testNoteOnUnreadableFileReportsRatherThanCrashing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxoff-not-here-\(UUID().uuidString).png")
        XCTAssertEqual(ArtworkInspector.note(for: missing), "Could not read image dimensions")
    }

    func testThumbnailIsBoundedByMaxPixelSize() throws {
        let url = try makeImage(width: 1400, height: 1400, name: "thumb.png")
        let image = try XCTUnwrap(ArtworkInspector.thumbnail(for: url, maxPixelSize: 128))
        XCTAssertLessThanOrEqual(image.size.width, 128)
        XCTAssertLessThanOrEqual(image.size.height, 128)
    }

    func testThumbnailOfMissingFileIsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxoff-not-here-\(UUID().uuidString).png")
        XCTAssertNil(ArtworkInspector.thumbnail(for: missing, maxPixelSize: 128))
    }

    // MARK: - Fixtures

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waxoff-artwork-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    /// Generates a solid-colour PNG with the bundled ffmpeg, so no binary
    /// fixtures are committed. Skips cleanly when the binaries are absent.
    private func makeImage(width: Int, height: Int, name: String) throws -> URL {
        let tools = try IntegrationFFmpeg.locate()
        let out = workDir.appendingPathComponent(name)
        try IntegrationFFmpeg.run(ffmpeg: tools.ffmpeg, args: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=blue:s=\(width)x\(height)",
            "-frames:v", "1",
            out.path
        ])
        return out
    }
}
