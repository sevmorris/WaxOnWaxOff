import SwiftUI

struct FileInfoStatsView: View {
    let file: FileItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info = file.fileInfo {
                infoRow(info)
            }
            if let stats = file.stats {
                statsRow(stats)
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ info: FileInfo) -> some View {
        HStack(spacing: 12) {
            statPair("", info.format)
            statPair("SR", formatSR(info.sampleRate))
            statPair("CH", info.channelCount == 2 ? "Stereo" : info.channelCount == 1 ? "Mono" : "\(info.channelCount)ch")
            if let bd = info.bitDepth {
                statPair("BIT", "\(bd)-bit")
            }
            statPair("DUR", formatDuration(info.duration))
            if let br = info.bitRate {
                statPair("BR", formatBR(br))
            }
        }
    }

    @ViewBuilder
    private func statsRow(_ stats: AudioStats) -> some View {
        HStack(spacing: 12) {
            statPair("RMS", String(format: "%.1f dBFS", stats.rms))
            statPair("PEAK", String(format: "%.1f dBFS", stats.peak))
            statPair("CREST", String(format: "%.1f dB", stats.crest))
            statPair("LUFS", String(format: "%.1f", stats.lufs))
        }
    }

    @ViewBuilder
    private func statPair(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            if !label.isEmpty {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func formatSR(_ hz: Double) -> String {
        if hz >= 1000 {
            let khz = hz / 1000
            let s = khz.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f kHz", khz)
                : String(format: "%.1f kHz", khz)
            return s
        }
        return String(format: "%.0f Hz", hz)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func formatBR(_ bps: Double) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", bps / 1_000_000)
        }
        return String(format: "%.0f kbps", bps / 1000)
    }
}
