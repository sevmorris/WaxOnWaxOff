import XCTest
@testable import WaxOnWaxOff

final class MP3ArgumentsTests: XCTestCase {

    private let input = URL(fileURLWithPath: "/tmp/in.wav")
    private let output = URL(fileURLWithPath: "/tmp/out.mp3")
    private let art = URL(fileURLWithPath: "/tmp/cover.png")
    private let chapters = URL(fileURLWithPath: "/tmp/chapters.txt")

    private func args(metadata: EpisodeMetadata, chaptersFile: URL?) -> [String] {
        DeliveryProcessor.mp3Arguments(
            input: input,
            output: output,
            title: "Fallback Stem",
            metadata: metadata,
            chaptersFile: chaptersFile,
            settings: WaxOffSettings(),
            outputChannelCount: 2
        )
    }

    /// The path following each `-i`, in order.
    private func inputPaths(_ args: [String]) -> [String] {
        var paths: [String] = []
        for (i, a) in args.enumerated() where a == "-i" && i + 1 < args.count {
            paths.append(args[i + 1])
        }
        return paths
    }

    /// Returns the value following the FIRST occurrence of `flag`. Do not use
    /// for flags that legitimately repeat in this argument list — `-map`,
    /// `-metadata` and `-metadata:s:v` all appear more than once, and this
    /// would silently check only the first. Use `contains(exactString)` there.
    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - The four input combinations

    func testNeitherChaptersNorArtwork() {
        let a = args(metadata: EpisodeMetadata(), chaptersFile: nil)
        XCTAssertEqual(inputPaths(a), ["/tmp/in.wav"])
        XCTAssertEqual(value(after: "-map", in: a), "0:a:0")
        XCTAssertFalse(a.contains("-map_chapters"))
        XCTAssertFalse(a.contains("attached_pic"))
    }

    func testChaptersOnly() {
        let a = args(metadata: EpisodeMetadata(), chaptersFile: chapters)
        XCTAssertEqual(inputPaths(a), ["/tmp/in.wav", "/tmp/chapters.txt"])
        XCTAssertEqual(value(after: "-map_chapters", in: a), "1")
        XCTAssertFalse(a.contains("attached_pic"))
    }

    func testArtworkOnly() {
        var m = EpisodeMetadata()
        m.artworkURL = art
        let a = args(metadata: m, chaptersFile: nil)
        XCTAssertEqual(inputPaths(a), ["/tmp/in.wav", "/tmp/cover.png"])
        // Artwork takes index 1 when there is no chapters input.
        XCTAssertTrue(a.contains("1:v:0"), "Expected artwork mapped from input 1, got: \(a)")
        XCTAssertTrue(a.contains("attached_pic"))
    }

    func testChaptersAndArtworkTogether() {
        var m = EpisodeMetadata()
        m.artworkURL = art
        let a = args(metadata: m, chaptersFile: chapters)
        XCTAssertEqual(inputPaths(a), ["/tmp/in.wav", "/tmp/chapters.txt", "/tmp/cover.png"])
        XCTAssertEqual(value(after: "-map_chapters", in: a), "1")
        XCTAssertTrue(a.contains("2:v:0"), "Expected artwork mapped from input 2, got: \(a)")
    }

    // MARK: - Tags

    func testEmptyEpisodeTitleFallsBackToStem() {
        let a = args(metadata: EpisodeMetadata(), chaptersFile: nil)
        XCTAssertTrue(a.contains("title=Fallback Stem"))
    }

    func testEpisodeTitleOverridesStem() {
        var m = EpisodeMetadata()
        m.episodeTitle = "Real Episode Title"
        let a = args(metadata: m, chaptersFile: nil)
        XCTAssertTrue(a.contains("title=Real Episode Title"))
        XCTAssertFalse(a.contains("title=Fallback Stem"))
    }

    func testPodcastNameBecomesAlbum() {
        var m = EpisodeMetadata()
        m.podcastName = "My Show"
        let a = args(metadata: m, chaptersFile: nil)
        XCTAssertTrue(a.contains("album=My Show"))
    }

    func testEmptyPodcastNameWritesNoAlbum() {
        let a = args(metadata: EpisodeMetadata(), chaptersFile: nil)
        XCTAssertFalse(a.contains(where: { $0.hasPrefix("album=") }))
    }

    func testTagValuesAreSanitized() {
        var m = EpisodeMetadata()
        m.episodeTitle = "Has=Equals"
        let a = args(metadata: m, chaptersFile: nil)
        XCTAssertTrue(a.contains("title=Has-Equals"),
                      "Expected FFmpegFilters.metadataValue sanitization, got: \(a)")
    }

    // MARK: - Invariants

    func testAlwaysWritesID3v23() {
        let a = args(metadata: EpisodeMetadata(), chaptersFile: nil)
        XCTAssertEqual(value(after: "-id3v2_version", in: a), "3")
    }

    func testOutputPathIsLast() {
        let a = args(metadata: EpisodeMetadata(), chaptersFile: nil)
        XCTAssertEqual(a.last, "/tmp/out.mp3")
    }

    func testSourceMetadataIsStillCarriedThrough() {
        let a = args(metadata: EpisodeMetadata(), chaptersFile: nil)
        XCTAssertEqual(value(after: "-map_metadata", in: a), "0")
    }

    // MARK: - Artwork flags

    func testArtworkEmitsCoverTagsAndStreamCopy() {
        var m = EpisodeMetadata()
        m.artworkURL = art
        let a = args(metadata: m, chaptersFile: nil)
        XCTAssertTrue(a.contains("-c:v"), "got: \(a)")
        XCTAssertTrue(a.contains("copy"))
        XCTAssertTrue(a.contains("-disposition:v"))
        XCTAssertTrue(a.contains("attached_pic"))
        XCTAssertTrue(a.contains("title=Album cover"))
        XCTAssertTrue(a.contains("comment=Cover (front)"))
    }

    func testNoArtworkEmitsNoVideoCodecFlags() {
        let a = args(metadata: EpisodeMetadata(), chaptersFile: nil)
        XCTAssertFalse(a.contains("-c:v"))
        XCTAssertFalse(a.contains("-disposition:v"))
    }

    // MARK: - Settings are honoured

    func testNonDefaultSettingsAndChannelCountAreHonoured() {
        var settings = WaxOffSettings()
        settings.truePeak = -3.0
        settings.mp3Bitrate = 128
        let a = DeliveryProcessor.mp3Arguments(
            input: input, output: output, title: "Stem",
            metadata: EpisodeMetadata(), chaptersFile: nil,
            settings: settings, outputChannelCount: 1
        )
        XCTAssertTrue(a.contains("128k"), "bitrate not honoured: \(a)")
        XCTAssertTrue(a.contains("1"), "channel count not honoured")
        // Limiter sits 1 dB below the configured true peak: -3.0 - 1.0 = -4.0 dBFS.
        let expected = FFmpegFilters.limiterCeilingAmplitude(dBFS: -4.0)
        XCTAssertTrue(a.contains(where: { $0.contains("alimiter=limit=\(expected)") }),
                      "limiter ceiling not derived from settings.truePeak: \(a)")
    }

    // MARK: - Whitespace handling

    func testWhitespaceOnlyEpisodeTitleFallsBackToStem() {
        var m = EpisodeMetadata()
        m.episodeTitle = "   "
        let a = args(metadata: m, chaptersFile: nil)
        XCTAssertTrue(a.contains("title=Fallback Stem"), "got: \(a)")
    }

    func testWhitespaceOnlyPodcastNameWritesNoAlbum() {
        var m = EpisodeMetadata()
        m.podcastName = "  \t "
        let a = args(metadata: m, chaptersFile: nil)
        XCTAssertFalse(a.contains(where: { $0.hasPrefix("album=") }), "got: \(a)")
    }

    func testPodcastNameIsSanitized() {
        var m = EpisodeMetadata()
        m.podcastName = "Show=Name"
        let a = args(metadata: m, chaptersFile: nil)
        XCTAssertTrue(a.contains("album=Show-Name"), "got: \(a)")
    }
}
