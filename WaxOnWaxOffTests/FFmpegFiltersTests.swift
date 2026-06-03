import XCTest
@testable import WaxOnWaxOff

final class FFmpegFiltersTests: XCTestCase {
    func testAresampleDoesNotIncludeDither() {
        // dither_method=triangular_hp was removed: 24-bit PCM output has no
        // word-length reduction that would require dithering.
        let filter = FFmpegFilters.aresample(to: 44100)
        XCTAssertFalse(filter.contains("dither_method"),
                       "aresample must not inject dither; 24-bit output requires no word-length reduction")
        XCTAssertTrue(filter.contains("44100"))
    }

    // MARK: - metadataValue

    // These tests pin the sanitization contract for FFmpegFilters.metadataValue.
    // IMPORTANT: backslash safety below depends on values being passed via
    // Process.arguments (not shell interpolation). If a future code path uses
    // shell interpolation, backslashes must also be escaped — revisit all callers.

    func testMetadataValueSanitizesEquals() {
        // `=` splits a key=value pair; must be replaced.
        XCTAssertEqual(FFmpegFilters.metadataValue("key=value"), "key-value")
        XCTAssertEqual(FFmpegFilters.metadataValue("a=b=c"), "a-b-c")
    }

    func testMetadataValueSanitizesNewlines() {
        // Embedded newlines corrupt single-line tag formats like MP3 ID3.
        XCTAssertEqual(FFmpegFilters.metadataValue("line1\nline2"), "line1 line2")
        XCTAssertEqual(FFmpegFilters.metadataValue("a\nb\nc"), "a b c")
    }

    func testMetadataValuePreservesBackslashes() {
        // Backslashes are intentionally NOT sanitized: substituting them would
        // silently rewrite titles like "Episode 12\3" to "Episode 12/3".
        // Safety is provided by Process.arguments usage (no shell interpolation).
        XCTAssertEqual(FFmpegFilters.metadataValue("Episode 12\\3"), "Episode 12\\3")
        XCTAssertEqual(FFmpegFilters.metadataValue("a\\b\\c"), "a\\b\\c")
    }

    func testMetadataValuePassesThroughCleanStrings() {
        let clean = "My Podcast Episode 42"
        XCTAssertEqual(FFmpegFilters.metadataValue(clean), clean)
    }
}
