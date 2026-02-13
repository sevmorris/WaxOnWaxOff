import SwiftUI

struct WaveformView: View {
    let waveformData: WaveformData?

    private let dbLevels: [Double] = [0, -1, -2, -3, -4, -5, -6, -12, -18, -24, -36, -48]

    var body: some View {
        Group {
            if let data = waveformData {
                HStack(spacing: 4) {
                    dbScale
                        .frame(width: 32)

                    ZStack {
                        dbGridLines

                        WaveformShape(data: data)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var dbScale: some View {
        GeometryReader { geometry in
            let midY = geometry.size.height / 2

            ZStack {
                ForEach(dbLevels, id: \.self) { db in
                    let amplitude = pow(10, db / 20)
                    let yOffset = (1 - amplitude) * midY

                    // Top label (positive side)
                    Text(formatDb(db))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .position(x: 16, y: yOffset)

                    // Bottom label (mirrored, only for 0 dB)
                    if db == 0 {
                        Text(formatDb(db))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .position(x: 16, y: geometry.size.height - yOffset)
                    }
                }
            }
        }
    }

    private var dbGridLines: some View {
        GeometryReader { geometry in
            let midY = geometry.size.height / 2

            Path { path in
                // Center line (0 amplitude)
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: geometry.size.width, y: midY))

                // dB level lines
                for db in dbLevels {
                    let amplitude = pow(10, db / 20)
                    let yOffset = (1 - amplitude) * midY

                    // Top line
                    path.move(to: CGPoint(x: 0, y: yOffset))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: yOffset))

                    // Bottom line (mirrored)
                    path.move(to: CGPoint(x: 0, y: geometry.size.height - yOffset))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height - yOffset))
                }
            }
            .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
        }
    }

    private func formatDb(_ db: Double) -> String {
        if db == 0 {
            return "0"
        }
        return String(format: "%.0f", db)
    }
}

struct WaveformShape: Shape {
    let data: WaveformData

    func path(in rect: CGRect) -> Path {
        var path = Path()

        guard !data.peaks.isEmpty else { return path }

        let midY = rect.midY
        let sampleWidth = rect.width / CGFloat(data.peaks.count)

        // Draw the waveform as mirrored peaks
        path.move(to: CGPoint(x: 0, y: midY))

        // Top half (positive)
        for (index, peak) in data.peaks.enumerated() {
            let x = CGFloat(index) * sampleWidth + sampleWidth / 2
            let height = CGFloat(peak) * rect.height / 2
            path.addLine(to: CGPoint(x: x, y: midY - height))
        }

        // Continue to bottom half (mirrored)
        for (index, peak) in data.peaks.enumerated().reversed() {
            let x = CGFloat(index) * sampleWidth + sampleWidth / 2
            let height = CGFloat(peak) * rect.height / 2
            path.addLine(to: CGPoint(x: x, y: midY + height))
        }

        path.closeSubpath()

        return path
    }
}

#Preview {
    WaveformView(waveformData: WaveformData(samples: [], peaks: [0.8, 0.5, 0.9, 0.3, 0.7, 0.6, 0.4]))
        .frame(height: 100)
        .padding()
}
