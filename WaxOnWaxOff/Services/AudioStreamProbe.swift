import Foundation

/// Lightweight ffprobe checks used before analysis / processing.
enum AudioStreamProbe {
    /// True when the file contains at least one audio stream FFmpeg can decode.
    nonisolated static func hasAudioStream(ffprobe: String, url: URL) async -> Bool {
        do {
            let output = try await FFmpegRunner.captureStdout(exe: ffprobe, args: [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=codec_type",
                "-of", "default=nw=1:nk=1",
                url.path
            ])
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "audio"
        } catch {
            return false
        }
    }
}
