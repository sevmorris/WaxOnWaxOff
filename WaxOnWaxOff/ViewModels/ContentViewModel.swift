import AppKit
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "ContentVM")

@Observable
@MainActor
final class ContentViewModel {
    let fileQueue = FileQueueCoordinator()
    var settings: WaxOnSettings {
        didSet {
            settings.save()
            syncNoiseFloorHPF()
        }
    }
    var isProcessing = false
    var alertMessage: String?
    var showWaxonWarning = false
    private var pendingWaxonFiles: [URL] = []
    var presetStore = WaxOnPresetStore()
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

    /// Whether the file list can be edited.
    ///
    /// A batch works from a snapshot taken at Process, so removing rows mid-run
    /// stops nothing — the completion callbacks simply stop finding their rows,
    /// and files keep landing on disk with no UI left showing them. WaxOn has
    /// no verification tail, so unlike WaxOff's version of this there is no
    /// window where a batch is outstanding but editing is harmless.
    var canEditFileList: Bool { !isProcessing }

    // nonisolated: with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the implicit
    // deinit would be MainActor-isolated, and macOS 15's isolated-deinit runtime
    // (swift_task_deinitOnExecutor, reached via the back-deploy shim) malloc-aborts
    // tearing down its task-local scope when the last release happens outside a
    // task — e.g. RootContentView's @State view model being discarded when the
    // window closes. Nothing in teardown needs the actor, so opt out.
    nonisolated deinit {}

    init() {
        self.settings = WaxOnSettings.load()
        syncNoiseFloorHPF()
        if let preset = presetStore.selectedPreset {
            settings = preset.settings
        }
    }

    private func syncNoiseFloorHPF() {
        fileQueue.noiseFloorHighPassHz = settings.highPassEnabled ? 80 : 20
    }

    func addFiles(_ urls: [URL]) {
        alertMessage = fileQueue.addFiles(
            urls,
            skippedFormatMessage: { count in
                "\(count) file\(count == 1 ? "" : "s") skipped — unsupported format. Supported: wav, aif, aiff, aifc, mp3, flac, m4a, caf, aac, mp4, mov."
            },
            beforeCommit: { valid in
                if valid.contains(where: OutputNaming.looksLikeWaxOnPrep) {
                    self.pendingWaxonFiles = valid
                    self.showWaxonWarning = true
                    return false
                }
                return true
            }
        )
    }

    func confirmWaxonWarning() {
        let toAdd = pendingWaxonFiles
        pendingWaxonFiles = []
        showWaxonWarning = false
        fileQueue.commitFiles(toAdd)
    }

    func dismissWaxonWarning() {
        pendingWaxonFiles = []
        showWaxonWarning = false
    }

    // Guarded here rather than at each call site. Disabling the toolbar's
    // Remove and Clear covered one route into these and left the list's own
    // two — swipe-to-delete and the Delete key — wide open, so the rule held
    // only where somebody had remembered to apply it. Same shape as the
    // toolbar deriving its own state: a rule enforced by the view is a rule
    // with holes in it.
    func removeSelected() {
        guard canEditFileList else { return }
        fileQueue.removeSelected()
    }
    func clearAll() {
        guard canEditFileList else { return }
        fileQueue.clearAll()
    }
    func removeFiles(at offsets: IndexSet) {
        guard canEditFileList else { return }
        fileQueue.removeFiles(at: offsets)
    }
    // Not guarded: reordering removes nothing, and the batch matches its
    // callbacks to rows by id rather than by position.
    func moveFiles(from source: IndexSet, to destination: Int) { fileQueue.moveFiles(from: source, to: destination) }

    func applyPreset(_ preset: WaxOnPreset) {
        settings = preset.settings
        presetStore.selectPreset(preset.id)
    }

    func saveCurrentAsPreset(name: String) {
        presetStore.savePreset(WaxOnPreset(name: name, settings: settings))
    }

    func process() {
        guard !files.isEmpty else { return }

        if let customPath = settings.outputDirectoryPath,
           !FileManager.default.isWritableFile(atPath: customPath) {
            alertMessage = "Output directory is not writable: \(customPath)"
            return
        }

        let inputs = files.compactMap { file -> JobInput? in
            guard case .ready = file.status else { return nil }
            return JobInput(id: file.id, url: file.url)
        }
        guard !inputs.isEmpty else {
            alertMessage = "No files are ready to process — wait for analysis to finish or fix errors first."
            return
        }

        let outputDirectories = inputs.map {
            OutputDirectory.waxOnOutputDirectory(for: $0.url, settings: settings)
        }
        if let reason = OutputDirectory.unwritableReason(outputDirectories) {
            alertMessage = reason
            return
        }

        guard OutputDirectory.confirmDesktopFallback(outputDirectories: outputDirectories) else { return }

        let concurrentJobs = ProcessingConfig.maxConcurrentJobs
        if let reason = DiskSpaceChecker.waxOnBatchBlockedReason(
            inputURLs: inputs.map(\.url),
            outputDirectories: outputDirectories,
            concurrentJobs: concurrentJobs
        ) {
            alertMessage = reason
            return
        }

        isProcessing = true
        processingCancelled = false
        log.clear()
        fileQueue.snapshotReadyStats()

        let currentSettings = settings

        processingTask = Task {
            do {
                let processor = AudioProcessor(settings: currentSettings,
                    onFileStarted: { [weak self] id in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            guard !self.processingCancelled else { return }
                            guard let index = self.files.firstIndex(where: { $0.id == id }) else { return }
                            self.files[index].status = .processing
                        }
                    },
                    onFileCompleted: { [weak self] result in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            guard let id = result.id,
                                  let index = self.files.firstIndex(where: { $0.id == id }) else { return }
                            self.files[index].status = .processed(outputURL: result.output)
                            // Stats + output waveform from a single shared decode.
                            self.fileQueue.analyzeOutputFile(id: id, url: result.output)
                        }
                    },
                    onFileFailed: { [weak self] failure in
                        guard let self else { return }
                        Task { @MainActor [self] in
                            guard let index = self.files.firstIndex(where: { $0.id == failure.id }) else { return }
                            self.files[index].status = .error(failure.message)
                        }
                    },
                    onLog: { [weak self] message, level in
                        Task { @MainActor [weak self] in
                            self?.log.append(message, level: level)
                        }
                    })
                let batch = try await processor.run(inputs: inputs)

                fileQueue.restoreProcessingRows()

                if batch.failures.isEmpty {
                    NotificationService.showCompletionNotification(mode: .waxOn, fileCount: batch.successes.count)
                } else if batch.successes.isEmpty {
                    alertMessage = "Processing failed. Select the console button at the top right of the waveform area to see the details."
                } else {
                    alertMessage = "\(batch.successes.count) file\(batch.successes.count == 1 ? "" : "s") processed, \(batch.failures.count) failed. See Console for details."
                    NotificationService.showCompletionNotification(mode: .waxOn, fileCount: batch.successes.count)
                }
            } catch is CancellationError {
                // User cancelled — cancelProcessing() already restored row state
            } catch {
                logger.error("Processing failed: \(error.localizedDescription, privacy: .public)")
                log.append("✗ \(error.localizedDescription)", level: .info)
                fileQueue.restoreProcessingRows()
                alertMessage = "Processing failed. Select the console button at the top right of the waveform area to see the details."
            }

            isProcessing = false
            processingTask = nil
        }
    }

    func cancelProcessing() {
        processingCancelled = true
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        fileQueue.restoreProcessingRowsAfterCancel()
    }
}
