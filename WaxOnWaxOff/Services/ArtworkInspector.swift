import Foundation
import AppKit
import ImageIO

/// Reads cover-art dimensions and thumbnails without decoding the full image.
/// Separated from `MetadataSheet` because it is pure inspection with no view
/// state, and because the sheet is about to grow a chapter table.
enum ArtworkInspector {

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
