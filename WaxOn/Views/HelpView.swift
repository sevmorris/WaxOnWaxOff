import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                section("Getting Started") {
                    text("""
                    WaxOn prepares raw podcast recordings for editing in a DAW. \
                    It handles high-pass filtering, loudness normalization, phase rotation, \
                    and brick-wall limiting in a single drag-and-drop workflow, outputting \
                    clean 24-bit WAV files ready for import into Logic Pro or any other editor.
                    """)
                    steps([
                        "Choose your sample rate (44.1 kHz or 48 kHz) and output format (Mono or Stereo).",
                        "Set the ceiling to control maximum peak level (e.g., -1 dB).",
                        "Drag and drop audio files onto the window.",
                        "Click Process.",
                        "Output files are saved alongside the originals with a -waxon suffix."
                    ])
                }
                section("Output Naming") {
                    code("{original-name}-{samplerate}waxon-{limit}dB.wav")
                    text("Example: episode-01-44kwaxon-1dB.wav")
                }
                section("Processing Pipeline") {
                    text("WaxOn uses FFmpeg with a multi-pass pipeline:")
                    numberedList([
                        "High-pass filtering, channel selection (if mono), phase rotation (if enabled), and resampling to the target sample rate.",
                        "Loudness normalization (if enabled) — two-pass EBU R128 analysis followed by linear gain application.",
                        "Brick-wall limiting with 2x oversampled true peak control."
                    ])
                    text("Output format: 24-bit WAV")
                }
                section("Main Settings") {
                    definition("Sample Rate", "Output sample rate — 44.1 kHz or 48 kHz.")
                    definition("Output", "Mono (with left/right channel selection) or Stereo passthrough.")
                    definition("Ceiling", "Brick-wall limiter ceiling, from -6 dB to -1 dB. Controls the maximum peak level of the output.")
                }
                section("Advanced Settings") {
                    definition("High Pass", "High-pass filter cutoff frequency (default 80 Hz, range 40–90 Hz). Removes low-frequency rumble, HVAC hum, and handling noise.")
                    definition("Loudness Norm", "When enabled, normalizes integrated loudness to the target level using EBU R128 measurement. Applies a single linear gain — no dynamic compression — so dynamics are fully preserved.")
                    definition("Target", "Integrated loudness target for normalization (default -30 LUFS, range -35 to -16 LUFS). Lower values leave more headroom for editing.")
                    definition("Phase Rotate", "150 Hz allpass filter that rotates phase relationships between harmonics, reducing the crest factor (peak-to-RMS ratio) of speech. This gives the limiter more headroom to work with, resulting in cleaner limiting. Enabled by default.")
                }
                Spacer()
            }
            .padding(30)
        }
        .frame(width: 540, height: 620)
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WaxOn Help")
                .font(.largeTitle.bold())
            Text("Podcast Audio Prep for macOS")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.bold())
            content()
        }
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func code(_ string: String) -> some View {
        Text(string)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.body.bold())
                        .frame(width: 20, alignment: .trailing)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func numberedList(_ items: [String]) -> some View {
        steps(items)
    }

    private func definition(_ term: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term)
                .font(.body.bold())
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

#Preview {
    HelpView()
}
