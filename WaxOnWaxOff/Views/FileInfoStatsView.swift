import SwiftUI

struct FileInfoStatsView: View {
    let file: FileItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info = file.outputFileInfo ?? file.fileInfo {
                infoRow(info)
            }
            Divider().padding(.vertical, 8)
            statsRow(file.outputStats ?? file.stats)
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

    private func statsRow(_ stats: AudioStats?) -> some View {
        HStack(alignment: .top, spacing: 20) {
            statBlock("RMS",   stats.map { String(format: "%.1f dBFS", $0.rms)   } ?? "---")
            statBlock("PEAK",  stats.map { String(format: "%.1f dBFS", $0.peak)  } ?? "---",
                      valueColor: stats.map { peakColor($0.peak) } ?? .primary)
            statBlock("CREST", stats.map { String(format: "%.1f dB",   $0.crest) } ?? "---")
            statBlock("LUFS",  stats.map { String(format: "%.1f",      $0.lufs)  } ?? "---")
        }
    }

    private func peakColor(_ peak: Double) -> Color {
        if peak >= 0   { return .red }
        if peak >= -3  { return .orange }
        return .primary
    }

    @ViewBuilder
    private func statBlock(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            Text(value)
                .font(.system(size: 12.5, weight: .medium).monospaced())
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
