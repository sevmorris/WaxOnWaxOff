import Foundation
import Observation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "io.github.sevmorris.WaxOnWaxOff", category: "DeliveryVM")

@Observable
@MainActor
final class DeliveryViewModel {
    let fileQueue = FileQueueCoordinator()
    var settings: WaxOffSettings {
        didSet { settings.save() }
    }
    var isProcessing = false
    var deliveryPhase: String? = nil
    var alertMessage: String?
    var presetStore = WaxOffPresetStore()
    var log = ProcessingLog()

    private var processingTask: Task<Void, Never>?

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
        self.settings = WaxOffSettings.load()
        if let preset = presetStore.selectedPreset {
            settings = preset.settings
        }
    }

    func addFiles(_ urls: [URL]) {
        alertMessage = fileQueue.addFiles(urls) { count in
            "\(count) file\(count == 1 ? "" : "s") skipped — unsupported format."
        }
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

        let readyFiles = files.filter {
            if case .ready = $0.status { return true }
            return false
        }
        guard !readyFiles.isEmpty else {
            alertMessage = "No files are ready to process — wait for analysis to finish or fix errors first."
            return
        }

        let outputDirectories = readyFiles.map { file in
            OutputDirectory.waxOffOutputDirectory(for: file.url, settings: settings)
        }
        if let reason = OutputDirectory.unwritableReason(outputDirectories) {
            alertMessage = reason
            return
        }
        if let reason = DiskSpaceChecker.waxOffBatchBlockedReason(
            inputURLs: readyFiles.map(\.url),
            outputDirectories: outputDirectories
        ) {
            alertMessage = reason
            return
        }

        isProcessing = true
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
                        Task { @MainActor [weak self] in
                            guard let self,
                                  let idx = self.files.firstIndex(where: { $0.id == id }) else { return }
                            self.files[idx].status = .processing
                        }
                    },
                    onPhase: { [weak self] id, phase in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.files.contains(where: { $0.id == id && $0.status == .processing }) else { return }
                            self.deliveryPhase = phase
                        }
                    },
                    onLog: { [weak self] message, level in
                        Task { @MainActor [weak self] in
                            self?.log.append(message, level: level)
                        }
                    }
                )

                for result in batch.successes {
                    if let idx = files.firstIndex(where: { $0.id == result.id }),
                       let primaryURL = result.outputURLs.first {
                        files[idx].status = .processed(outputURL: primaryURL)
                        fileQueue.generateOutputWaveform(id: result.id, url: primaryURL)
                    }
                }

                for failure in batch.failures {
                    if let idx = files.firstIndex(where: { $0.id == failure.id }) {
                        files[idx].status = .error("Processing failed — see Console")
                    }
                    log.append("✗ \(failure.message)", level: .info)
                }

                fileQueue.restoreProcessingRows()

                if !batch.successes.isEmpty {
                    await NotificationService.showCompletionNotification(
                        mode: .waxOff,
                        fileCount: batch.successes.count
                    )
                } else if !batch.failures.isEmpty {
                    alertMessage = "Processing failed. Open the Console tab for details."
                }
            } catch is CancellationError {
                fileQueue.restoreProcessingRowsAfterCancel()
            } catch {
                logger.error("Processing failed: \(error.localizedDescription, privacy: .public)")
                log.append("✗ \(error.localizedDescription)", level: .info)
                fileQueue.restoreProcessingRows()
                alertMessage = "Processing failed. Open the Console tab for details."
            }

            isProcessing = false
            deliveryPhase = nil
            processingTask = nil
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        deliveryPhase = nil
        fileQueue.restoreProcessingRowsAfterCancel()
    }
}
