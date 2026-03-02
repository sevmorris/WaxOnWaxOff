import SwiftUI

struct FileInfoStatsView: View {
    let file: FileItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info = file.fileInfo {
                infoRow(info)
            }
            if file.fileInfo != nil && file.stats != nil {
                Divider().padding(.vertical, 8)
            }
            if let stats = file.stats {
                statsRow(stats)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func infoRow(_ info: FileInfo) -> some View {
        HStack(alignment: .top, spacing: 20) {
            statBlock("FORMAT", info.format)
            statBlock("SR", formatSR(info.sampleRate))
            statBlock("CH", info.channelCount == 2 ? "Stereo" : info.channelCount == 1 ? "Mono" : "\(info.channelCount)ch")
            if let bd = info.bitDepth {
                statBlock("BIT", "\(bd)-bit")
            }
            statBlock("DUR", formatDuration(info.duration))
            if let br = info.bitRate {
                statBlock("BR", formatBR(br))
            }
        }
    }

    @ViewBuilder
    private func statsRow(_ stats: AudioStats) -> some View {
        HStack(alignment: .top, spacing: 20) {
            statBlock("RMS", String(format: "%.1f dBFS", stats.rms))
            statBlock("PEAK", String(format: "%.1f dBFS", stats.peak))
            statBlock("CREST", String(format: "%.1f dB", stats.crest))
            statBlock("LUFS", String(format: "%.1f", stats.lufs))
        }
    }

    @ViewBuilder
    private func statBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            Text(value)
                .font(.system(size: 12.5, weight: .medium).monospaced())
                .foregroundStyle(.primary)
        }
    }

    private func formatSR(_ hz: Double) -> String {
        if hz >= 1000 {
            let khz = hz / 1000
            return khz.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f kHz", khz)
                : String(format: "%.1f kHz", khz)
        }
        return String(format: "%.0f Hz", hz)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func formatBR(_ bps: Double) -> String {
        bps >= 1_000_000
            ? String(format: "%.1f Mbps", bps / 1_000_000)
            : String(format: "%.0f kbps", bps / 1000)
    }
}
