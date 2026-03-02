import Foundation

actor FFmpegManager {
    struct Paths: Sendable {
        let ffmpeg: String
        let ffprobe: String
    }

    private var cachedPaths: Paths?

    static let shared = FFmpegManager()

    private init() {}

    func ensureTools() throws -> Paths {
        if let paths = cachedPaths {
            return paths
        }

        let paths = try locateTools()
        cachedPaths = paths
        return paths
    }

    private func locateTools() throws -> Paths {
        let fm = FileManager.default

        if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
           let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil),
           fm.fileExists(atPath: ffmpegURL.path),
           fm.fileExists(atPath: ffprobeURL.path) {
            return Paths(ffmpeg: ffmpegURL.path, ffprobe: ffprobeURL.path)
        }

        if let resourceURL = Bundle.main.resourceURL {
            let ffmpegURL = resourceURL.appendingPathComponent("ffmpeg")
            let ffprobeURL = resourceURL.appendingPathComponent("ffprobe")
            if fm.fileExists(atPath: ffmpegURL.path),
               fm.fileExists(atPath: ffprobeURL.path) {
                return Paths(ffmpeg: ffmpegURL.path, ffprobe: ffprobeURL.path)
            }
        }

        let paths = try copyToTemp()
        return paths
    }

    private func copyToTemp() throws -> Paths {
        let fm = FileManager.default
        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WaxOn/bin", isDirectory: true)

        try fm.createDirectory(at: tempBase, withIntermediateDirectories: true)

        let ffmpegDst = tempBase.appendingPathComponent("ffmpeg")
        let ffprobeDst = tempBase.appendingPathComponent("ffprobe")

        try copyResource("ffmpeg", to: ffmpegDst)
        try copyResource("ffprobe", to: ffprobeDst)

        try makeExecutable(ffmpegDst)
        try makeExecutable(ffprobeDst)

        return Paths(ffmpeg: ffmpegDst.path, ffprobe: ffprobeDst.path)
    }

    private func copyResource(_ name: String, to destination: URL) throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            if fm.isExecutableFile(atPath: destination.path) {
                return
            }
            try? fm.removeItem(at: destination)
        }

        guard let sourceURL = Bundle.main.url(forResource: name, withExtension: nil) ??
              Bundle.main.resourceURL?.appendingPathComponent(name),
              fm.fileExists(atPath: sourceURL.path) else {
            throw ProcessingError.ffmpegNotFound
        }

        try fm.copyItem(at: sourceURL, to: destination)
    }

    private func makeExecutable(_ url: URL) throws {
        let path = url.path
        let fm = FileManager.default

        var attributes = try fm.attributesOfItem(atPath: path)
        attributes[.posixPermissions] = NSNumber(value: 0o755)
        try fm.setAttributes(attributes, ofItemAtPath: path)

        if !fm.isExecutableFile(atPath: path) {
            chmod(path, 0o755)
        }
    }
}
