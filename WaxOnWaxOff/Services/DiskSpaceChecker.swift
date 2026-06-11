import AVFoundation
import Foundation

enum DiskSpaceChecker {
    /// Scratch headroom beyond the estimated temp footprint.
    private static let tempHeadroomBytes: Int64 = 200 * 1024 * 1024
    /// Per-output-directory headroom when writing finished files.
    private static let outputHeadroomBytes: Int64 = 100 * 1024 * 1024

    /// WaxOn keeps up to five full-size intermediate files per concurrent job in app temp:
    /// (1) midURL — HPF/channel output, (2) dynLevelURL — optional dynamic leveling output,
    /// (3) nrTempURL — optional NR analysis temp, (4) normURL — optional loudnorm output,
    /// (5) tmpURL — final limiter output awaiting move. If stages are added to AudioProcessor,
    /// update this multiplier to match.
    private static let waxOnTempMultiplier: Int64 = 5

    /// WaxOff holds at most two temp files per job: (1) wavTempURL — the normalized WAV
    /// before it is moved to the final location, and (2) mp3TempURL — the encoded MP3 temp
    /// (only present when MP3 output is requested). If stages are added to DeliveryProcessor,
    /// update this multiplier to match.
    private static let waxOffTempMultiplier: Int64 = 2

    static func waxOnBatchBlockedReason(
        inputURLs: [URL],
        outputDirectories: [URL],
        concurrentJobs: Int
    ) -> String? {
        guard !inputURLs.isEmpty else { return nil }

        let decodedSizes = inputURLs.map { decodedPCMBytes(for: $0) }
        guard decodedSizes.contains(where: { $0 > 0 }) else { return nil }

        let largestDecoded = decodedSizes.max() ?? 0
        let workers = max(1, min(concurrentJobs, inputURLs.count))

        let tempRequired = largestDecoded * waxOnTempMultiplier * Int64(workers) + tempHeadroomBytes
        if let reason = insufficientSpaceReason(
            requiredBytes: tempRequired,
            at: FileManager.waxonTempDirectory,
            context: "temporary processing files"
        ) {
            return reason
        }

        var requiredPerDirectory: [String: Int64] = [:]
        for (decoded, dir) in zip(decodedSizes, outputDirectories) {
            let bytes = decoded > 0 ? decoded : largestDecoded
            let key = dir.path
            requiredPerDirectory[key, default: outputHeadroomBytes] += bytes
        }

        for (path, required) in requiredPerDirectory {
            if let reason = insufficientSpaceReason(
                requiredBytes: required,
                at: URL(fileURLWithPath: path, isDirectory: true),
                context: "processed output files"
            ) {
                return reason
            }
        }

        return nil
    }

    static func waxOffBatchBlockedReason(
        inputURLs: [URL],
        outputDirectories: [URL]
    ) -> String? {
        guard !inputURLs.isEmpty else { return nil }

        let decodedSizes = inputURLs.map { decodedPCMBytes(for: $0) }
        guard decodedSizes.contains(where: { $0 > 0 }) else { return nil }

        let largestDecoded = decodedSizes.max() ?? 0
        let tempRequired = largestDecoded * waxOffTempMultiplier + tempHeadroomBytes
        if let reason = insufficientSpaceReason(
            requiredBytes: tempRequired,
            at: FileManager.waxonTempDirectory,
            context: "temporary processing files"
        ) {
            return reason
        }

        var requiredPerDirectory: [String: Int64] = [:]
        for (decoded, dir) in zip(decodedSizes, outputDirectories) {
            let bytes = decoded > 0 ? decoded : largestDecoded
            let key = dir.path
            // WAV + MP3 "Both" can exceed 2× decoded size (PCM + compressed);
            // multiply by 3 for a conservative upper bound on output footprint.
            requiredPerDirectory[key, default: outputHeadroomBytes] += bytes * 3
        }

        for (path, required) in requiredPerDirectory {
            if let reason = insufficientSpaceReason(
                requiredBytes: required,
                at: URL(fileURLWithPath: path, isDirectory: true),
                context: "delivery output files"
            ) {
                return reason
            }
        }

        return nil
    }

    private static func insufficientSpaceReason(
        requiredBytes: Int64,
        at directory: URL,
        context: String
    ) -> String? {
        guard let available = availableBytes(at: directory) else { return nil }
        guard available < requiredBytes else { return nil }

        let needMB = max(1, requiredBytes / (1024 * 1024))
        let haveMB = max(0, available / (1024 * 1024))
        let volume = directory.path
        return "Not enough disk space for \(context) on “\(volume)” (\(haveMB) MB free, about \(needMB) MB needed). Free space and try again."
    }

    private static func availableBytes(at url: URL) -> Int64? {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ]),
        let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return capacity
    }

    /// Estimate the decoded 24-bit PCM footprint of `url` by opening the file
    /// with AVAudioFile and computing `frameCount × 3 bytes × channelCount`.
    /// This gives an accurate size regardless of input container/codec (e.g., a
    /// 64 kbps MP3 decodes to ~17× its container size). Falls back to the
    /// container file size if AVAudioFile cannot open the URL.
    private static func decodedPCMBytes(for url: URL) -> Int64 {
        if let file = try? AVAudioFile(forReading: url) {
            let channels = Int64(max(1, file.processingFormat.channelCount))
            let frames = file.length
            if frames > 0 {
                return frames * 3 * channels
            }
        }
        return fileSize(at: url) ?? 0
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else {
            return nil
        }
        if let allocated = values.totalFileAllocatedSize {
            return Int64(allocated)
        }
        if let size = values.fileSize {
            return Int64(size)
        }
        return nil
    }
}
