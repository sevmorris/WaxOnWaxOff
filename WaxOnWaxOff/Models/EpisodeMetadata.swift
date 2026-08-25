import Foundation

/// A single podcast chapter mark. Only the start time is stored: ID3 `CHAP`
/// requires a start and an end, but ends are derivable — chapter *i* ends where
/// *i+1* begins, and the last ends at the file duration. Storing ends would let
/// the two drift apart.
struct Chapter: Identifiable, Equatable, Sendable {
    let id: UUID
    var start: TimeInterval
    var title: String

    init(id: UUID = UUID(), start: TimeInterval, title: String) {
        self.id = id
        self.start = start
        self.title = title
    }
}

/// Per-episode podcast metadata written into the delivered MP3's ID3v2.3 tag.
/// Kept out of `WaxOffSettings` and the preset system deliberately: `episodeTitle`,
/// `artworkURL` and `chapters` are unique to each episode, and holding `podcastName`
/// here too means one value type carries everything the metadata editor changes for
/// a file, instead of splitting that state across two homes.
struct EpisodeMetadata: Equatable, Sendable {
    /// ID3 `TALB`.
    var podcastName: String = ""
    /// ID3 `TIT2`. Empty means "fall back to the output stem", which is the
    /// behaviour WaxOff had before this feature existed.
    var episodeTitle: String = ""
    /// ID3 `APIC`, front cover.
    var artworkURL: URL?
    /// ID3 `CHAP` + `CTOC`.
    var chapters: [Chapter] = []

    var isEmpty: Bool {
        podcastName.isEmpty
            && episodeTitle.isEmpty
            && artworkURL == nil
            && chapters.isEmpty
    }
}
