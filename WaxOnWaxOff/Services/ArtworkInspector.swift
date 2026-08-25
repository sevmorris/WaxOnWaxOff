import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Reads cover-art dimensions and thumbnails without decoding the full image.
/// Separated from `MetadataSheet` because it is pure inspection with no view
/// state, and because the sheet is about to grow a chapter table.
enum ArtworkInspector {

    /// What a drag onto the artwork well amounts to. `rejected` carries the
    /// line to show the user: a drop that quietly does nothing reads as the
    /// well being broken rather than the file being wrong.
    enum Drop: Equatable {
        case accepted(URL)
        case rejected(String)
    }

    /// Decides a drop onto the artwork well, accepting exactly what the
    /// `Choose…` panel accepts (`allowedContentTypes = [.png, .jpeg]`).
    ///
    /// The format check reads the file's header rather than its path
    /// extension. `URLResourceValues.contentType` would not do: on macOS a
    /// file's type is bound from its extension, so anything at all renamed to
    /// `cover.png` claims to be `public.png` and would be accepted here, then
    /// fail at encode time with no explanation. `CGImageSourceGetType` reports
    /// what the bytes actually are — and it is the same ImageIO read
    /// `thumbnail(for:)` and `note(for:)` already do, so the well is never
    /// showing art that those two cannot read.
    ///
    /// Directories are refused up front: `isRegularFile` is false for them, and
    /// a directory reaching FFmpeg as `-i` fails the whole encode. The delivery
    /// path guards against that too, but by then the user is a long way from
    /// the drag that caused it.
    nonisolated static func evaluate(drop urls: [URL]) -> Drop {
        guard urls.count == 1, let url = urls.first else {
            return .rejected(urls.isEmpty
                             ? "Nothing to use as artwork"
                             : "Drop a single PNG or JPEG image")
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            return .rejected("Not a PNG or JPEG image")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier),
              type.conforms(to: .png) || type.conforms(to: .jpeg)
        else {
            return .rejected("Not a PNG or JPEG image")
        }
        return .accepted(url)
    }

    /// Decodes a small thumbnail instead of the full image. Cover art is
    /// routinely 3000×3000; `NSImage(contentsOf:)` inside a view's `body` would
    /// decode all nine megapixels again on every keystroke elsewhere in the sheet.
    nonisolated static func thumbnail(for url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Reads pixel dimensions from the image header without decoding pixels.
    /// Apple Podcasts asks for a square cover between 1400 and 3000 px; anything
    /// outside that is reported as a note, never a refusal — the delivered MP3
    /// is still a valid file and the user may have a reason.
    nonisolated static func note(for url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return "Could not read image dimensions" }

        let size = "\(width)×\(height)"
        if width != height { return "\(size) — not square" }
        if width < 1400 { return "\(size) — below Apple Podcasts' 1400 px minimum" }
        if width > 3000 { return "\(size) — above Apple Podcasts' 3000 px maximum" }
        return size
    }
}
