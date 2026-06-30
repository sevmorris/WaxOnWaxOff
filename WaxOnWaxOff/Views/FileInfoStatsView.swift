import SwiftUI

struct FileInfoStatsView: View {
    let file: FileItem
    /// When false (WaxOff), the FLOOR stat is still shown but never warning/critical-
    /// colored — the high-noise-floor heuristic targets raw speech, not finished mixes.
    var applyFloorWarnings: Bool = true

    private var showingOutput: Bool { file.outputStats != nil || file.outputFileInfo != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info = file.outputFileInfo ?? file.fileInfo {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showingOutput {
                        Text("OUTPUT")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.brandAccent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.brandAccent.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    infoRow(info)
                }
            }
            Divider().padding(.vertical, 8)
            statsRow(file.outputStats ?? file.stats)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func infoRow(_ info: FileInfo) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
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
    }

    private func statsRow(_ stats: AudioStats?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                statBlock("RMS",   stats.map { String(format: "%.1f dBFS", $0.rms)   } ?? "---")
                statBlock("PEAK", stats.map { String(format: "%.1f dBFS", $0.peak) } ?? "---",
                          valueColor: stats.map { peakColor($0.peak) } ?? .primary,
                          help: "Sample peak (max absolute sample). Orange ≥ −3 dBFS; red ≥ 0 dBFS.")
                if let s = stats, s.hasElevatedTruePeak {
                    statBlock("ISP (est.)", String(format: "%.1f dBFS", s.truePeak),
                              valueColor: peakColor(s.truePeak),
                              help: "Inter-sample peak lower bound from 2× linear interpolation. NOT a BS.1770 true peak — the real true peak may be higher. For broadcast-accurate TP, see the “measured” line in the Console after processing.")
                }
                statBlock("CREST", stats.map { String(format: "%.1f dB",   $0.crest) } ?? "---")
                statBlock(showingOutput ? "LUFS" : "LUFS (src)", stats.map { String(format: "%.1f", $0.lufs) } ?? "---",
                          help: showingOutput
                            ? "Integrated loudness (ITU-R BS.1770) of the processed file."
                            : "Integrated loudness of the source file before WaxOn/WaxOff processing.")
                if let nf = stats?.noiseFloor {
                    statBlock("FLOOR", String(format: "%.1f dBFS", nf),
                              valueColor: noiseFloorColor(nf),
                              help: applyFloorWarnings
                                ? "Orange: high noise floor (> −50 dBFS)  •  Red: very high (> −40 dBFS)"
                                : "Estimated noise floor. Not flagged in WaxOff — a finished mix may legitimately carry continuous low-level content (music beds, room tone).")
                }
            }
        }
    }

    private func peakColor(_ peak: Double) -> Color {
        if peak >= 0   { return .meterCritical }
        if peak >= -3  { return .meterWarning }
        return .primary
    }

    /// Severity of a measured noise floor (dBFS). Warnings only make sense for raw,
    /// unedited speech (WaxOn); a finished delivery mix (WaxOff) may legitimately carry
    /// continuous low-level content (music beds, room tone under a mix), so callers
    /// pass `applyWarnings: false` there to classify everything as `.normal`.
    enum FloorSeverity: Equatable { case normal, warning, critical }

    static func floorSeverity(dBFS nf: Double, applyWarnings: Bool) -> FloorSeverity {
        guard applyWarnings else { return .normal }
        if nf > -40 { return .critical }
        if nf > -50 { return .warning }
        return .normal
    }

    private func noiseFloorColor(_ nf: Double) -> Color {
        switch Self.floorSeverity(dBFS: nf, applyWarnings: applyFloorWarnings) {
        case .normal:   return .primary
        case .warning:  return .meterWarning
        case .critical: return .meterCritical
        }
    }

    @ViewBuilder
    private func statBlock(_ label: String, _ value: String, valueColor: Color = .primary, help: String = "") -> some View {
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
        .fixedSize()
        .help(help)
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
