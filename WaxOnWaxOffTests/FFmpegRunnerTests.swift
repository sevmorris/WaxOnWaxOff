import XCTest
@testable import WaxOnWaxOff

final class FFmpegRunnerTests: XCTestCase {

    func testParseLoudnormJSONExtractsStringValues() {
        let stderr = """
        [Parsed_loudnorm_0 @ 0x600003d14000] {
            "input_i" : "-23.50",
            "input_tp" : "-1.20",
            "input_lra" : "5.00",
            "input_thresh" : "-33.00",
            "target_offset" : "4.50"
        }
        """
        let dict = FFmpegRunner.parseLoudnormJSON(from: stderr)
        XCTAssertEqual(dict?["input_i"], "-23.50")
        XCTAssertEqual(dict?["input_tp"], "-1.20")
        XCTAssertEqual(dict?["input_lra"], "5.00")
        XCTAssertEqual(dict?["input_thresh"], "-33.00")
        XCTAssertEqual(dict?["target_offset"], "4.50")
    }

    func testParseLoudnormJSONIgnoresLaterBraceNoise() {
        let stderr = """
        [Parsed_loudnorm_0 @ 0x1] { "input_i" : "-20.0" }
        unrelated filter dump { "not" : "loudnorm" }
        """
        let dict = FFmpegRunner.parseLoudnormJSON(from: stderr)
        XCTAssertEqual(dict?["input_i"], "-20.0")
        XCTAssertNil(dict?["not"])
    }

    func testParseLoudnormJSONReturnsNilWhenMissing() {
        XCTAssertNil(FFmpegRunner.parseLoudnormJSON(from: "no json here"))
    }

    /// When the `[Parsed_loudnorm_` anchor isn't present, the parser falls back
    /// to "first `{` in stderr". Locks the current contract so a future FFmpeg
    /// log format change doesn't silently regress this path.
    func testParseLoudnormJSONFallsBackToFirstBraceWithoutPrefix() {
        let stderr = """
        ffmpeg version 8.0 banner
        { "input_i": "-22.0", "input_tp": "-1.5", "input_lra": "5", "input_thresh": "-32", "target_offset": "4" }
        """
        let dict = FFmpegRunner.parseLoudnormJSON(from: stderr)
        XCTAssertEqual(dict?["input_i"], "-22.0")
        XCTAssertEqual(dict?["target_offset"], "4")
    }

    func testParseEbur128FrameMetadataTakesFinalFrameValues() {
        // Realistic two-frame excerpt of `ametadata=mode=print:file=-` output.
        // The final frame's whole-file values must win, and the LRA.low /
        // LRA.high / true_peaks_chN keys must not collide with the LRA= /
        // true_peak= prefixes.
        let stdout = """
        frame:5998 pts:26451180 pts_time:599.8
        lavfi.r128.M=-16.012
        lavfi.r128.S=-17.388
        lavfi.r128.I=-19.001
        lavfi.r128.LRA=6.100
        lavfi.r128.LRA.low=-22.710
        lavfi.r128.LRA.high=-16.330
        lavfi.r128.true_peaks_ch0=0.500
        lavfi.r128.true_peaks_ch1=0.500
        lavfi.r128.true_peak=0.500
        frame:5999 pts:26455590 pts_time:599.9
        lavfi.r128.M=-15.943
        lavfi.r128.S=-17.254
        lavfi.r128.I=-18.657
        lavfi.r128.LRA=6.370
        lavfi.r128.LRA.low=-22.710
        lavfi.r128.LRA.high=-16.340
        lavfi.r128.true_peaks_ch0=0.615
        lavfi.r128.true_peaks_ch1=0.610
        lavfi.r128.true_peak=0.615
        """
        let m = FFmpegRunner.parseEbur128FrameMetadata(from: stdout)
        XCTAssertEqual(m?.integrated, -18.657)
        XCTAssertEqual(m?.lra, 6.37, "LRA.low/LRA.high must not shadow the LRA= key")
        // 20·log10(0.615) — full-precision dBTP from the linear frame value
        XCTAssertEqual(try XCTUnwrap(m?.truePeakDB), -4.2225, accuracy: 0.001)
    }

    func testParseEbur128FrameMetadataSilenceMapsToNegativeInfinity() {
        let stdout = """
        frame:1 pts:4410 pts_time:0.1
        lavfi.r128.I=-70.000
        lavfi.r128.LRA=0.000
        lavfi.r128.true_peak=0.000
        """
        let m = FFmpegRunner.parseEbur128FrameMetadata(from: stdout)
        XCTAssertEqual(m?.truePeakDB, -Double.infinity,
                       "zero linear peak (digital silence) must map to -inf dBTP, not crash log10")
    }

    func testParseEbur128FrameMetadataReturnsNilWhenKeysMissing() {
        XCTAssertNil(FFmpegRunner.parseEbur128FrameMetadata(from: "no metadata here"))
        XCTAssertNil(FFmpegRunner.parseEbur128FrameMetadata(from: """
        frame:1 pts:4410 pts_time:0.1
        lavfi.r128.I=-18.000
        lavfi.r128.LRA=6.000
        """), "missing true_peak key must fail the parse, not fabricate a value")
    }

    func testFilterEscapeHandlesSyntaxCharacters() {
        XCTAssertEqual(FFmpegRunner.filterEscape("path/to/file"), "path/to/file")
        XCTAssertEqual(FFmpegRunner.filterEscape("a:b"), "a\\:b")
        XCTAssertEqual(FFmpegRunner.filterEscape("it's"), "it\\'s")
        XCTAssertEqual(FFmpegRunner.filterEscape("a\\b"), "a\\\\b")
        XCTAssertEqual(FFmpegRunner.filterEscape("[0:a]"), "\\[0\\:a\\]")
        XCTAssertEqual(FFmpegRunner.filterEscape("a,b"), "a\\,b")
        XCTAssertEqual(FFmpegRunner.filterEscape("a;b"), "a\\;b")
    }

    func testEffectiveTimeoutSecondsReturnsCorrectBounds() {
        XCTAssertEqual(FFmpegRunner.effectiveTimeoutSeconds(for: nil),        900)
        XCTAssertEqual(FFmpegRunner.effectiveTimeoutSeconds(for: .infinity),  900)
        XCTAssertEqual(FFmpegRunner.effectiveTimeoutSeconds(for: .nan),       900)
        XCTAssertEqual(FFmpegRunner.effectiveTimeoutSeconds(for: -1.0),       900)
        XCTAssertEqual(FFmpegRunner.effectiveTimeoutSeconds(for: 1e300),      900)
        XCTAssertEqual(FFmpegRunner.effectiveTimeoutSeconds(for: 10.0),       300)
        XCTAssertEqual(FFmpegRunner.effectiveTimeoutSeconds(for: 1000.0),    4000)
    }

    func testRunThrowsProcessingErrorOnNonExecutablePath() async {
        // /etc/hosts exists on macOS but is not an executable binary;
        // process.run() throws, landing in the launchFlag-guard catch branch
        // as ProcessingError.ffmpegFailed rather than crashing with
        // NSInvalidArgumentException. Pins the T1-1 Path A guard.
        let nonExe = "/etc/hosts"
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonExe))
        do {
            try await FFmpegRunner.run(exe: nonExe, args: [])
            XCTFail("Expected ProcessingError — run should throw on a non-executable path")
        } catch is ProcessingError {
            // Expected — launchFlag guard surfaced the failure correctly
        } catch {
            XCTFail("Expected ProcessingError but got \(type(of: error)): \(error)")
        }
    }
}
