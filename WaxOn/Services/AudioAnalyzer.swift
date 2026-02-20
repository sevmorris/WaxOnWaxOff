import Foundation
import AVFoundation

enum AudioAnalyzer {
    static func analyze(url: URL) async throws -> AudioStats {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let stats = try performAnalysis(url: url)
                    continuation.resume(returning: stats)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performAnalysis(url: URL) throws -> AudioStats {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProcessingError.analysisError("File does not exist")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ProcessingError.analysisError("Could not open audio file: \(error.localizedDescription)")
        }

        let format = file.processingFormat
        let frameCount = Int64(file.length)

        guard frameCount > 0 else {
            throw ProcessingError.analysisError("Audio file is empty")
        }

        let chunkSize: AVAudioFrameCount = 32768
        let channels = Int(format.channelCount)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            throw ProcessingError.analysisError("Could not create audio buffer")
        }

        file.framePosition = 0
        var sumSquares: Double = 0
        var peak: Double = 0
        var totalFrames: Int = 0

        while file.framePosition < frameCount {
            do {
                try file.read(into: buffer)
            } catch {
                if totalFrames > 0 { break }
                throw ProcessingError.analysisError("Error reading audio: \(error.localizedDescription)")
            }

            if buffer.frameLength == 0 { break }

            guard let channelData = buffer.floatChannelData else {
                throw ProcessingError.analysisError("Could not access channel data")
            }

            let frames = Int(buffer.frameLength)
            for frame in 0..<frames {
                var monoSample: Float = 0
                for channel in 0..<channels {
                    monoSample += channelData[channel][frame]
                }
                monoSample /= Float(channels)
                let doubleMono = Double(monoSample)
                sumSquares += doubleMono * doubleMono

                for channel in 0..<channels {
                    let channelSample = abs(Double(channelData[channel][frame]))
                    peak = max(peak, channelSample)
                }
            }
            totalFrames += frames
        }

        guard totalFrames > 0 else {
            throw ProcessingError.analysisError("No frames to process")
        }

        let rms = sqrt(sumSquares / Double(totalFrames))
        let rmsDb = 20 * log10(max(rms, 1e-12))
        let peakDb = 20 * log10(max(peak, 1e-12))
        let crestDb = peakDb - rmsDb

        return AudioStats(rms: rmsDb, peak: peakDb, crest: crestDb)
    }
}
