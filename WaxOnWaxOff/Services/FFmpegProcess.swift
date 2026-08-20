// Shared verbatim across the sibling app repos (DoublEnder, WaxOnWaxOff,
// ClipHack). Keep the copies byte-identical: scripts/check-shared.sh compares
// them and a release preflight fails when they drift. Anything app-specific
// belongs in that repo's release.sh, not here.
//
// This file is the mechanism of running one ffmpeg process — launch, capture,
// watchdog, cancellation, crash triage — and nothing about policy. How long a
// given invocation may run, and what its output means, stay in each app's
// FFmpegRunner, which is why they can differ without this file differing.
//
// It expects the enclosing module to define `ProcessingError` with the cases
// `ffmpegNotFound` and `ffmpegFailed(code:message:)`. That contract is checked
// by the compiler: renaming a case breaks this file's build in that repo
// immediately, which is the failure this arrangement is trying to have.

@preconcurrency import Foundation

/// Runs a single ffmpeg/ffprobe process to completion, with a watchdog and
/// structured cancellation.
///
/// The subtlety here is telling four terminations apart — normal exit, a
/// watchdog timeout, a user cancel, and an ffmpeg crash — because FFmpeg
/// catches SIGTERM and exits normally with code 255 and `terminationReason
/// == .exit`. Without the flags below, a crashed child reads as a cancel and
/// silently aborts every other job in the batch.
enum FFmpegProcess {

    enum CaptureTarget { case stderr, stdout }

    /// Run `exe` with `args`, returning its exit status and the captured
    /// stream. Throws `ProcessingError.ffmpegNotFound` if the binary is
    /// missing, `ProcessingError.ffmpegFailed` on timeout, launch failure or
    /// crash, and `CancellationError` when the surrounding task is cancelled.
    ///
    /// A non-zero exit is *not* an error here — it comes back in the tuple, so
    /// the caller can attach the stderr text to whatever error it wants to
    /// raise.
    static func launch(
        exe: String,
        args: [String],
        capture: CaptureTarget,
        timeoutSeconds: Int
    ) async throws -> (Int32, String) {
        guard FileManager.default.fileExists(atPath: exe) else {
            throw ProcessingError.ffmpegNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice

        // Tracks whether *we* sent SIGTERM via the onCancel handler. Set before
        // calling process.terminate() so the terminationHandler can distinguish
        // a deliberate user-cancel from an ffmpeg crash (SIGSEGV, SIGABRT, OOM
        // SIGKILL, etc.). Without this flag, any signal-terminated child would be
        // reported as CancellationError, silently aborting the entire batch.
        let cancelFlag = TimeoutFlag()

        // Set to true only after process.run() returns without throwing. Guards all
        // process.terminate() call sites: both the watchdog and the onCancel handler
        // must be no-ops if the process was never launched, because calling
        // terminate() on an unlaunched Process raises NSInvalidArgumentException.
        let launchFlag = TimeoutFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), Error>) in
                let pipe = Pipe()
                switch capture {
                case .stderr:
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = pipe
                case .stdout:
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                }

                // nonisolated: same treatment as TimeoutFlag below — the box is
                // captured by the pipe-reader closure on the utility queue and by
                // the termination handler, so its last release happens off-task;
                // an implicit MainActor deinit would malloc-abort in macOS 15's
                // isolated-deinit runtime. All state is touched only from those
                // nonisolated queues anyway, per the @unchecked Sendable marking.
                nonisolated final class DataBox: @unchecked Sendable { var value = Data() }
                let box = DataBox()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.value = pipe.fileHandleForReading.readDataToEndOfFile()
                    readGroup.leave()
                }

                // Watchdog. The flag distinguishes a timeout-triggered SIGTERM
                // from a user-cancel SIGTERM so the terminationHandler can
                // surface a "timed out after Ns" error instead of an opaque
                // CancellationError. Lock guards the read/write across the
                // watchdog queue and the terminationHandler queue.
                let timeoutFlag = TimeoutFlag()
                let timeoutItem = DispatchWorkItem {
                    timeoutFlag.set()
                    if launchFlag.didFire {
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(timeoutSeconds),
                    execute: timeoutItem
                )

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    readGroup.wait()
                    if timeoutFlag.didFire {
                        continuation.resume(throwing: ProcessingError.ffmpegFailed(
                            code: -1,
                            message: "ffmpeg timed out after \(timeoutSeconds) seconds"
                        ))
                        return
                    }
                    // Check cancel flag first — FFmpeg catches SIGTERM and exits
                    // normally with code 255 and reason .exit (not .uncaughtSignal),
                    // so terminationReason alone cannot distinguish a user cancel
                    // from an ordinary non-zero exit.
                    if cancelFlag.didFire {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    // Not cancelled by us. An unexpected signal is an ffmpeg crash
                    // (SIGSEGV, SIGABRT, OOM SIGKILL, etc.) — surface as a real error
                    // so callers don't silently cancel every other in-flight batch job.
                    // Note: on Darwin, terminationStatus holds the signal number when
                    // terminationReason == .uncaughtSignal.
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ProcessingError.ffmpegFailed(
                            code: proc.terminationStatus,
                            message: "ffmpeg crashed (signal \(proc.terminationStatus))"
                        ))
                        return
                    }
                    let msg = String(data: box.value, encoding: .utf8) ?? ""
                    continuation.resume(returning: (proc.terminationStatus, msg))
                }

                do {
                    try process.run()
                    launchFlag.set()
                    // Close the race window: if onCancel fired between the launchFlag
                    // check and launchFlag.set() above, we must terminate the now-running
                    // process ourselves — onCancel saw launchFlag unset and skipped it.
                    if cancelFlag.didFire {
                        process.terminate()
                    }
                } catch {
                    timeoutItem.cancel()
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(
                        code: -1,
                        message: "Failed to launch: \(error.localizedDescription)"
                    ))
                }
            }
        } onCancel: {
            cancelFlag.set()
            if launchFlag.didFire {
                process.terminate()
            }
        }
    }
}

/// Lock-guarded "did this happen?" flag, safe to read on the termination
/// queue and write on the dispatch queue that runs the timeout work item.
/// The class is `nonisolated` because the dispatch queues that touch it are
/// outside the MainActor default isolation — and the implicit MainActor deinit it
/// would otherwise get malloc-aborts in macOS 15's isolated-deinit runtime when
/// the last release happens off-task (these flags are released on those queues).
private nonisolated final class TimeoutFlag: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var fired = false

    nonisolated func set() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    nonisolated var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
