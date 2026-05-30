import Foundation
import Observation
import OSLog
import SwiftUI

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
                "\(count) file\(count == 1 ? "" : "s") skipped — unsupported format. Supported: wav, aif, aiff, aifc, mp3, flac, m4a, ogg, opus, caf, wma, aac, mp4, mov."
            },
            beforeCommit: { valid in
                if valid.contains(where: { $0.lastPathComponent.localizedCaseInsensitiveContains("-waxon") }) {
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

    func removeSelected() { fileQueue.removeSelected() }
    func clearAll() { fileQueue.clearAll() }
    func removeFiles(at offsets: IndexSet) { fileQueue.removeFiles(at: offsets) }
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
        let concurrentJobs = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
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
                    onLog: { [weak self] message, level in
                        Task { @MainActor [weak self] in
                            self?.log.append(message, level: level)
                        }
                    })
                let batch = try await processor.run(inputs: inputs)

                for result in batch.successes {
                    if let id = result.id,
                       let index = files.firstIndex(where: { $0.id == id }) {
                        files[index].status = .processed(outputURL: result.output)
                    }
                }

                for failure in batch.failures {
                    if let index = files.firstIndex(where: { $0.id == failure.id }) {
                        files[index].status = .error(failure.message)
                    }
                }

                fileQueue.restoreProcessingRows()

                for result in batch.successes {
                    if let id = result.id {
                        fileQueue.generateOutputWaveform(id: id, url: result.output)
                        fileQueue.analyzeOutputFile(id: id, url: result.output)
                    }
                }

                if batch.failures.isEmpty {
                    await NotificationService.showCompletionNotification(mode: .waxOn, fileCount: batch.successes.count)
                } else if batch.successes.isEmpty {
                    alertMessage = "Processing failed. Open the Console tab for details."
                } else {
                    alertMessage = "\(batch.successes.count) file\(batch.successes.count == 1 ? "" : "s") processed, \(batch.failures.count) failed. See Console for details."
                    await NotificationService.showCompletionNotification(mode: .waxOn, fileCount: batch.successes.count)
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
