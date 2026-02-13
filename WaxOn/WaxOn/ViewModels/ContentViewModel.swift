import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class ContentViewModel {
    var files: [FileItem] = []
    var selectedFileIDs: Set<UUID> = []
    var settings: WaxOnSettings {
        didSet { settings.save() }
    }
    var isProcessing = false
    var alertMessage: String?
    var showAdvanced = false
    private var processingTask: Task<Void, Never>?

    init() {
        self.settings = WaxOnSettings.load()
    }

    func addFiles(_ urls: [URL]) {
        let audioURLs = urls.filter { $0.isFileURL }
        let newFiles = audioURLs.map { FileItem(url: $0) }
        files.append(contentsOf: newFiles)

        for file in newFiles {
            analyzeFile(file)
            generateWaveform(file)
        }
    }

    func removeSelected() {
        files.removeAll { selectedFileIDs.contains($0.id) }
        selectedFileIDs.removeAll()
    }

    func clearAll() {
        files.removeAll()
        selectedFileIDs.removeAll()
    }

    func removeFiles(at offsets: IndexSet) {
        let deletedIDs = Set(offsets.map { files[$0].id })
        files.remove(atOffsets: offsets)
        selectedFileIDs.subtract(deletedIDs)
    }

    func process() {
        guard !files.isEmpty else { return }
        isProcessing = true

        let currentSettings = settings
        let inputs = files.map { JobInput(id: $0.id, url: $0.url) }

        // Snapshot stats so they survive the status transition
        for i in files.indices {
            if case .ready(let stats) = files[i].status {
                files[i].analysisStats = stats
            }
        }

        processingTask = Task {
            do {
                let processor = AudioProcessor(settings: currentSettings)
                let results = try await processor.run(inputs: inputs)

                for result in results {
                    if let id = result.id,
                       let index = files.firstIndex(where: { $0.id == id }) {
                        files[index].status = .processed(outputURL: result.output)
                    }
                }

                await NotificationService.showCompletionNotification(fileCount: results.count)
            } catch is CancellationError {
                // User cancelled — no alert needed
            } catch {
                alertMessage = error.localizedDescription
            }

            isProcessing = false
            processingTask = nil
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    private func analyzeFile(_ file: FileItem) {
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        files[index].status = .analyzing

        Task {
            do {
                let stats = try await AudioAnalyzer.analyze(url: file.url)
                if let currentIndex = files.firstIndex(where: { $0.id == file.id }) {
                    files[currentIndex].status = .ready(stats)
                }
            } catch {
                if let currentIndex = files.firstIndex(where: { $0.id == file.id }) {
                    files[currentIndex].status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func generateWaveform(_ file: FileItem) {
        Task {
            do {
                let waveform = try await WaveformGenerator.generate(url: file.url)
                if let currentIndex = files.firstIndex(where: { $0.id == file.id }) {
                    files[currentIndex].waveform = waveform
                }
            } catch {
                // Waveform generation failed silently - not critical
            }
        }
    }
}
