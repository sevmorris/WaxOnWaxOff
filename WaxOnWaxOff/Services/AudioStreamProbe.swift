import Foundation

/// Lightweight ffprobe checks used before analysis / processing.
///
/// `nonisolated`: pure process plumbing, callable from any context.
nonisolated enum AudioStreamProbe {
    /// What probing a file found — including whether ffprobe ran at all.
    ///
    /// "No audio" and "ffprobe never ran" used to be the same `false`. On
    /// 2026-09-16 the bundled ffprobe could not launch on macOS 26.7 (dyld
    /// refused a binary without LC_UUID), and every file was reported as having
    /// no audio stream, which sent the diagnosis after the files instead.
    enum Outcome: Equatable, Sendable {
        /// ffprobe read the file and found an audio stream.
        case audio
        /// ffprobe ran, and either found no audio stream or could not read the
        /// file. Both are a property of the file.
        case noAudio
        /// ffprobe did not run to an exit of its own: missing, not launchable,
        /// crashed or timed out. Says nothing about the file.
        case probeFailed(String)

        /// The error to report, or nil when the file has audio.
        var failure: ProcessingError? {
            switch self {
            case .audio: return nil
            case .noAudio: return .noAudioStream
            case .probeFailed(let detail): return .probeFailed(detail)
            }
        }
    }

    /// Probes the file's first audio stream. Throws only `CancellationError`.
    ///
    /// Always interrogates stream `a:0` (the first audio track). Any FFmpeg
    /// processing invocation that operates on the same file must use
    /// `-map 0:a:0` to select the same stream explicitly; FFmpeg's default
    /// "best audio" heuristic picks the stream with the highest channel count,
    /// which can differ from `a:0` (e.g. a MOV with stereo `a:0` and 5.1 `a:1`).
    ///
    /// Calls `FFmpegProcess.launch` rather than `FFmpegRunner.captureStdout`
    /// because the distinction lives there: `launch` throws when the process
    /// never reached an exit of its own, and returns the exit status when it
    /// did. The runner turns both into the same error.
    static func probe(ffprobe: String, url: URL) async throws -> Outcome {
        let exitCode: Int32
        let output: String
        do {
            (exitCode, output) = try await FFmpegProcess.launch(
                exe: ffprobe,
                args: [
                    "-v", "error",
                    "-select_streams", "a:0",
                    "-show_entries", "stream=codec_type",
                    "-of", "default=nw=1:nk=1",
                    url.path
                ],
                capture: .stdout,
                timeoutSeconds: FFmpegRunner.effectiveTimeoutSeconds(for: nil)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ProcessingError.ffmpegNotFound {
            return .probeFailed("it is missing from the app")
        } catch ProcessingError.ffmpegFailed(_, let message) {
            return .probeFailed(message)
        } catch {
            return .probeFailed(error.localizedDescription)
        }
        // A non-zero exit of ffprobe's own is it refusing the file.
        guard exitCode == 0 else { return .noAudio }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "audio" ? .audio : .noAudio
    }
}
