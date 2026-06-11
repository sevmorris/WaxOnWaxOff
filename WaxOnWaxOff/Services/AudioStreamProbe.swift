import Foundation

/// Lightweight ffprobe checks used before analysis / processing.
enum AudioStreamProbe {
    /// True when the file contains at least one audio stream FFmpeg can decode.
    ///
    /// Always interrogates stream `a:0` (the first audio track). Any FFmpeg
    /// processing invocation that operates on the same file must use
    /// `-map 0:a:0` to select the same stream explicitly; FFmpeg's default
    /// "best audio" heuristic picks the stream with the highest channel count,
    /// which can differ from `a:0` (e.g. a MOV with stereo `a:0` and 5.1 `a:1`).
    ///
    /// - Parameter onLog: Called with a brief error excerpt when ffprobe exits
    ///   non-zero or throws — distinguishing a process failure from a clean
    ///   "no audio stream" result (exit 0, empty output). Intended for the
    ///   verbose/debug log; the user-facing error string is set by the caller.
    nonisolated static func hasAudioStream(
        ffprobe: String,
        url: URL,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async -> Bool {
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
            // Process error (non-zero exit, timeout, crash) — distinct from a
            // clean "no audio stream" result. Log the detail for diagnosis.
            // Note: stderr is unavailable here because captureStdout discards it;
            // the error description contains the exit code and any captured output.
            if let onLog {
                let detail = String(error.localizedDescription.prefix(300))
                onLog("ffprobe process error for \(url.lastPathComponent): \(detail)")
            }
            return false
        }
    }
}
