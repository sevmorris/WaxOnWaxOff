import Foundation

enum DiskSpaceChecker {
    /// Scratch headroom beyond the estimated temp footprint.
    private static let tempHeadroomBytes: Int64 = 200 * 1024 * 1024
    /// Per-output-directory headroom when writing finished files.
    private static let outputHeadroomBytes: Int64 = 100 * 1024 * 1024

    /// WaxOn keeps several full-size intermediates per concurrent job in app temp.
    private static let waxOnTempMultiplier: Int64 = 5

    /// WaxOff may hold a decoded/normalized WAV temp plus delivery outputs.
    private static let waxOffTempMultiplier: Int64 = 2

    static func waxOnBatchBlockedReason(
        inputURLs: [URL],
        outputDirectories: [URL],
        concurrentJobs: Int
    ) -> String? {
        guard !inputURLs.isEmpty else { return nil }

        let sizes = inputURLs.compactMap { fileSize(at: $0) }
        guard !sizes.isEmpty else { return nil }

        let largestInput = sizes.max() ?? 0
        let workers = max(1, min(concurrentJobs, inputURLs.count))

        let tempRequired = largestInput * waxOnTempMultiplier * Int64(workers) + tempHeadroomBytes
        if let reason = insufficientSpaceReason(
            requiredBytes: tempRequired,
            at: FileManager.waxonTempDirectory,
            context: "temporary processing files"
        ) {
            return reason
        }

        var requiredPerDirectory: [String: Int64] = [:]
        for (url, dir) in zip(inputURLs, outputDirectories) {
            let inputBytes = fileSize(at: url) ?? largestInput
            let key = dir.path
            requiredPerDirectory[key, default: outputHeadroomBytes] += inputBytes
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

        let sizes = inputURLs.compactMap { fileSize(at: $0) }
        guard !sizes.isEmpty else { return nil }

        let largestInput = sizes.max() ?? 0
        let tempRequired = largestInput * waxOffTempMultiplier + tempHeadroomBytes
        if let reason = insufficientSpaceReason(
            requiredBytes: tempRequired,
            at: FileManager.waxonTempDirectory,
            context: "temporary processing files"
        ) {
            return reason
        }

        var requiredPerDirectory: [String: Int64] = [:]
        for (url, dir) in zip(inputURLs, outputDirectories) {
            let inputBytes = fileSize(at: url) ?? largestInput
            let key = dir.path
            requiredPerDirectory[key, default: outputHeadroomBytes] += inputBytes * 2
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
