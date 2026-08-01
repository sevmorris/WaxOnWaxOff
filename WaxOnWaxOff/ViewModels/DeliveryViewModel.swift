import AppKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "DeliveryVM")

@Observable
@MainActor
final class DeliveryViewModel {
    let fileQueue = FileQueueCoordinator()
    var settings: WaxOffSettings {
        didSet { settings.save() }
    }
    var isProcessing = false
    /// Live processing phase per file, keyed by `FileItem.id`. Delivery runs
    /// concurrently, so a single shared phase string would show whichever file
    /// emitted last, attributed to none of them (#23). An entry goes in on
    /// `onPhase` and comes out when that file reaches a terminal state —
    /// completed or failed — not when the batch ends.
    var filePhases: [UUID: String] = [:]
    /// Completed verification passes for the current batch, or nil when none is
    /// running. Batch-level, not per-file: a row reaches `.processed` when its
    /// output is written, before its own verification runs, so verification
    /// cannot be attributed to a row. No denominator — see `drainVerifications`.
    var verificationsCompleted: Int? = nil
    var alertMessage: String?
    var showWaxoffWarning = false
    private var pendingWaxoffFiles: [URL] = []
    var presetStore = WaxOffPresetStore()
    var log = ProcessingLog()

    private var processingTask: Task<Void, Never>?
    private var processingCancelled = false

    var files: [FileItem] {
        get { fileQueue.files }
        set { fileQueue.files = newValue }
    }
    var selectedFileIDs: Set<UUID> {
        get { fileQueue.selectedFileIDs }
        set { fileQueue.selectedFileIDs = newValue }
    }
    var isAnyFileAnalyzing: Bool { fileQueue.isAnyFileAnalyzing }

    /// True when every loaded file with known channel info is single-channel. The mono
    /// delivery control only applies to mono sources; for stereo, mixed, or an empty
    /// queue it stays inert. (The pipeline independently ignores the setting for any
    /// stereo source, so this only governs whether the control is enabled in the UI.)
    var allLoadedSourcesMono: Bool {
        let known = files.compactMap(\.fileInfo)
        guard !known.isEmpty else { return false }
        return known.allSatisfy { $0.channelCount == 1 }
    }

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. RootContentView's @State view model being discarded when the
    // window closes. Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}

    init() {
        self.settings = WaxOffSettings.load()
        if let preset = presetStore.selectedPreset {
            settings = preset.settings
        }
    }

    func addFiles(_ urls: [URL]) {
        alertMessage = fileQueue.addFiles(
            urls,
            skippedFormatMessage: { count in
                "\(count) file\(count == 1 ? "" : "s") skipped — unsupported format."
            },
            beforeCommit: { valid in
                if valid.contains(where: OutputNaming.looksLikeWaxOffDelivery) {
                    self.pendingWaxoffFiles = valid
                    self.showWaxoffWarning = true
                    return false
                }
                return true
            }
        )
    }

    func confirmWaxoffWarning() {
        let toAdd = pendingWaxoffFiles
        pendingWaxoffFiles = []
        showWaxoffWarning = false
        fileQueue.commitFiles(toAdd)
    }

    func dismissWaxoffWarning() {
        pendingWaxoffFiles = []
        showWaxoffWarning = false
    }

    func removeSelected() { fileQueue.removeSelected() }
    func clearAll() { fileQueue.clearAll() }
    func removeFiles(at offsets: IndexSet) { fileQueue.removeFiles(at: offsets) }
    func moveFiles(from source: IndexSet, to destination: Int) { fileQueue.moveFiles(from: source, to: destination) }

    func applyPreset(_ preset: WaxOffPreset) {
        settings = preset.settings
        presetStore.selectPreset(preset.id)
    }

    func saveCurrentAsPreset(name: String) {
        presetStore.savePreset(WaxOffPreset(name: name, settings: settings))
    }

    func process() {
        guard !files.isEmpty else { return }

        if let customPath = settings.outputDirectoryPath,
           !FileManager.default.isWritableFile(atPath: customPath) {
            alertMessage = "Output directory is not writable: \(customPath)"
            return
        }

        // Fail closed on files whose fileInfo is nil — analysis either failed or
        // hasn't finished yet, so channel count is unknown. Mono files are handled
        // correctly by DeliveryProcessor (upmixed to dual-mono before loudnorm).
        var analysisIncompleteCount = 0
        for i in files.indices {
            guard case .ready = files[i].status else { continue }
            guard files[i].fileInfo != nil else {
                files[i].status = .error("File analysis incomplete — channel count could not be determined. Wait for analysis to finish, then try again.")
                analysisIncompleteCount += 1
                continue
            }
        }

        let readyFiles = files.filter {
            if case .ready = $0.status { return true }
            return false
        }
        guard !readyFiles.isEmpty else {
            if analysisIncompleteCount > 0 {
                alertMessage = "No processable files — wait for file analysis to complete, then try again."
            } else {
                alertMessage = "No files are ready to process — wait for analysis to finish or fix errors first."
            }
            return
        }

        let outputDirectories = readyFiles.map { file in
            OutputDirectory.waxOffOutputDirectory(for: file.url, settings: settings)
        }
        if let reason = OutputDirectory.unwritableReason(outputDirectories) {
            alertMessage = reason
            return
        }

        guard OutputDirectory.confirmDesktopFallback(outputDirectories: outputDirectories) else { return }

        if let reason = DiskSpaceChecker.waxOffBatchBlockedReason(
            inputURLs: readyFiles.map(\.url),
            outputDirectories: outputDirectories
        ) {
            alertMessage = reason
            return
        }

        isProcessing = true
        processingCancelled = false
        log.clear()
        fileQueue.snapshotReadyStats()

        let currentSettings = settings
        let inputs = readyFiles.map { DeliveryJobInput(id: $0.id, url: $0.url) }

        processingTask = Task {
            do {
                let processor = DeliveryProcessor()
                let batch = try await processor.run(
                    inputs: inputs,
                    settings: currentSettings,
                    onFileStarted: { [weak self] id in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            guard !self.processingCancelled else { return }
                            guard let idx = self.files.firstIndex(where: { $0.id == id }) else { return }
                            self.files[idx].status = .processing
                        }
                    },
                    onFileCompleted: { [weak self] result in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            // Terminal state for this file: its phase entry goes
                            // out here, not at batch end. Removed before the
                            // status guard so a file with no output URL cannot
                            // leave a stale entry behind.
                            self.filePhases.removeValue(forKey: result.id)
                            guard let idx = self.files.firstIndex(where: { $0.id == result.id }),
                                  let primaryURL = result.outputURLs.first else { return }
                            self.files[idx].status = .processed(outputURL: primaryURL)
                            // Refresh the stats panel and output waveform against
                            // the rendered file (single shared decode) so the user
                            // can see what their WaxOff output landed at — mirrors
                            // WaxOn's post-process behavior.
                            self.fileQueue.analyzeOutputFile(id: result.id, url: primaryURL)
                        }
                    },
                    onFileFailed: { [weak self] failure in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            // The other terminal state — same removal, or a
                            // failed file keeps a phase on its row forever.
                            self.filePhases.removeValue(forKey: failure.id)
                            guard let idx = self.files.firstIndex(where: { $0.id == failure.id }) else { return }
                            self.files[idx].status = .error("Processing failed — see Console")
                        }
                    },
                    onPhase: { [weak self] id, phase in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.files.contains(where: { $0.id == id && $0.status == .processing }) else { return }
                            self.filePhases[id] = phase
                        }
                    },
                    onVerificationProgress: { [weak self] completed in
                        Task { @MainActor [weak self] in
                            self?.verificationsCompleted = completed
                        }
                    },
                    onLog: { [weak self] message, level in
                        Task { @MainActor [weak self] in
                            self?.log.append(message, level: level)
                        }
                    }
                )

                fileQueue.restoreProcessingRows()

                let partials = batch.successes.filter { $0.mp3FailureMessage != nil }
                if !batch.successes.isEmpty {
                    if !partials.isEmpty {
                        alertMessage = "\(partials.count) file\(partials.count == 1 ? "" : "s") had MP3 encoding failure (WAV complete). See Console for details."
                    }
                    await NotificationService.showCompletionNotification(
                        mode: .waxOff,
                        fileCount: batch.successes.count
                    )
                } else if !batch.failures.isEmpty {
                    alertMessage = "Processing failed. Open the Console tab for details."
                }
            } catch is CancellationError {
                // User cancelled — cancelProcessing() already restored row state
            } catch {
                logger.error("Processing failed: \(error.localizedDescription, privacy: .public)")
                log.append("✗ \(error.localizedDescription)", level: .info)
                fileQueue.restoreProcessingRows()
                alertMessage = "Processing failed. Open the Console tab for details."
            }

            isProcessing = false
            verificationsCompleted = nil
            // Safety net only. Phases are cleared per file on completion or
            // failure above; this catches an entry orphaned by a path that
            // reached neither — it is no longer what makes the readout correct.
            filePhases.removeAll()
            processingTask = nil
        }
    }

    func cancelProcessing() {
        processingCancelled = true
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        verificationsCompleted = nil
        filePhases.removeAll()
        fileQueue.restoreProcessingRowsAfterCancel()
    }
}
