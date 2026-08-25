import XCTest
@testable import WaxOnWaxOff

/// Covers `FileRowView.metadataSummary`, the tooltip behind the file row's tag
/// badge. It is the only place a user can see what a file carries without
/// opening the sheet, so a field that silently stops appearing here is a field
/// they will believe was never set.
final class MetadataSummaryTests: XCTestCase {

    func testEmptyMetadataSaysNoMetadata() {
        XCTAssertEqual(FileRowView.metadataSummary(EpisodeMetadata()), "No metadata")
    }

    // MARK: - Individual fields

    func testPodcastNameAppears() {
        var metadata = EpisodeMetadata()
        metadata.podcastName = "The Show"
        XCTAssertEqual(FileRowView.metadataSummary(metadata), "Podcast: The Show")
    }

    func testEpisodeTitleAppears() {
        var metadata = EpisodeMetadata()
        metadata.episodeTitle = "Episode 12"
        XCTAssertEqual(FileRowView.metadataSummary(metadata), "Title: Episode 12")
    }

    func testArtworkAppearsAsAPresenceFlag() {
        var metadata = EpisodeMetadata()
        metadata.artworkURL = URL(fileURLWithPath: "/tmp/cover.png")
        XCTAssertEqual(FileRowView.metadataSummary(metadata), "Artwork set")
    }

    func testChaptersAppearAsACount() {
        var metadata = EpisodeMetadata()
        metadata.chapters = [
            Chapter(start: 0, title: "Intro"),
            Chapter(start: 90, title: "Interview"),
            Chapter(start: 1800, title: "Outro")
        ]
        XCTAssertEqual(FileRowView.metadataSummary(metadata), "3 chapters")
    }

    // MARK: - Pluralization

    func testSingleChapterIsSingular() {
        var metadata = EpisodeMetadata()
        metadata.chapters = [Chapter(start: 0, title: "Only one")]
        XCTAssertEqual(FileRowView.metadataSummary(metadata), "1 chapter")
    }

    func testTwoChaptersArePlural() {
        var metadata = EpisodeMetadata()
        metadata.chapters = [
            Chapter(start: 0, title: "One"),
            Chapter(start: 10, title: "Two")
        ]
        XCTAssertEqual(FileRowView.metadataSummary(metadata), "2 chapters")
    }

    // MARK: - Combinations

    func testAllFieldsJoinOnNewlinesInDeclarationOrder() {
        var metadata = EpisodeMetadata()
        metadata.podcastName = "The Show"
        metadata.episodeTitle = "Episode 12"
        metadata.artworkURL = URL(fileURLWithPath: "/tmp/cover.jpg")
        metadata.chapters = [
            Chapter(start: 0, title: "Intro"),
            Chapter(start: 90, title: "Outro")
        ]
        XCTAssertEqual(FileRowView.metadataSummary(metadata), """
        Podcast: The Show
        Title: Episode 12
        Artwork set
        2 chapters
        """)
    }

    /// A gap in the middle must not leave a blank line behind — the parts array
    /// is built by appending, not by mapping over fixed slots.
    func testSkippedFieldsLeaveNoBlankLines() {
        var metadata = EpisodeMetadata()
        metadata.podcastName = "The Show"
        metadata.chapters = [Chapter(start: 0, title: "Intro")]
        XCTAssertEqual(FileRowView.metadataSummary(metadata), """
        Podcast: The Show
        1 chapter
        """)
    }

    /// Whitespace-only strings are not treated as empty here, and should not be:
    /// `MetadataSheet.save()` trims before committing, so anything that reaches
    /// this function has already been through that filter. Pinned so a future
    /// change to either side has to look at the other.
    func testTrimmingIsTheSheetsJobNotThisFunctions() {
        var metadata = EpisodeMetadata()
        metadata.podcastName = "  "
        XCTAssertEqual(FileRowView.metadataSummary(metadata), "Podcast:   ")
        XCTAssertFalse(metadata.isEmpty, "isEmpty tests raw strings too — the two agree")
    }
}
