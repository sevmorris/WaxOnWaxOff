import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                section("Overview") {
                    text("""
                    WaxOn/WaxOff is a two-mode podcast audio tool for macOS. Both modes \
                    share the same drag-and-drop file workflow, waveform viewer, and stats \
                    panel — they differ in what they do to your audio.
                    """)
                    text("""
                    Switch modes at any time using the WaxOn | WaxOff buttons in the top \
                    left of the window. Each mode keeps its own independent file list, so \
                    switching doesn't disturb your work in the other mode.
                    """)
                }

                dividerRow

                section("WaxOn — Raw Recording Prep") {
                    text("""
                    Use WaxOn on raw recordings before editing. It cleans up the signal — \
                    removing low-frequency rumble, controlling peak level, and optionally \
                    normalizing loudness — and outputs a clean 24-bit WAV ready to drop \
                    into Logic Pro or any other editor.
                    """)
                }
                section("WaxOn — Quick Start") {
                    steps([
                        "Set sample rate, output channels, and ceiling in the Settings strip.",
                        "Drag audio files onto the window (or the file list).",
                        "Click Process. Output files appear alongside the originals."
                    ])
                }
                section("WaxOn — Output Naming") {
                    code("{original-name}-{samplerate}waxon-{limit}dB.wav")
                    text("Example: interview-44kwaxon-1dB.wav")
                }
                section("WaxOn — Processing Pipeline") {
                    numberedList([
                        "High-pass filter at the chosen cutoff (default 80 Hz) — removes rumble, HVAC hum, and handling noise.",
                        "Channel selection (mono mode only) — extracts the left or right channel.",
                        "Resampling to the target sample rate.",
                        "Loudness normalization (if enabled) — two-pass EBU R128 analysis, then linear gain. No dynamic compression; dynamics are fully preserved.",
                        "Brick-wall limiting — 2× oversampled true peak control at the chosen ceiling."
                    ])
                    text("Output: 24-bit WAV.")
                }
                section("WaxOn — Settings") {
                    definition("Sample Rate", "44.1 kHz or 48 kHz. Match your DAW project setting.")
                    definition("Output", "Mono or Stereo. Mono extracts a single channel; Stereo passes both channels through unchanged.")
                    definition("Channel", "Left or Right — which channel to extract in Mono mode.")
                    definition("Ceiling", "Brick-wall limiter ceiling: −3, −2, or −1 dB. Controls the maximum true peak of the output.")
                    definition("High Pass", "High-pass filter cutoff frequency. Default 80 Hz, range 40–90 Hz.")
                    definition("Loudness Norm", "Enables EBU R128 loudness normalization. When off, only filtering and limiting are applied.")
                    definition("Target", "Integrated loudness target when Loudness Norm is on. Default −30 LUFS, range −35 to −16 LUFS. Lower values leave more headroom for editing.")
                    definition("Output Dir", "Where processed files are saved. Defaults to the same folder as the source.")
                }

                dividerRow

                section("WaxOff — Delivery & Mastering") {
                    text("""
                    Use WaxOff on your finished, edited mix. It applies broadcast-standard \
                    EBU R128 loudness normalization and delivers the result as 24-bit WAV, \
                    MP3, or both — ready to upload to your podcast host.
                    """)
                }
                section("WaxOff — Quick Start") {
                    steps([
                        "Select a preset from the menu in the header, or dial in your own settings.",
                        "Drag your finished mix file onto the window.",
                        "Click Process. Output files appear alongside the original."
                    ])
                }
                section("WaxOff — Output Naming") {
                    code("{original-name}-lev-{target}LUFS.wav / .mp3")
                    text("Example: episode-42-final-lev--18LUFS.wav")
                }
                section("WaxOff — Processing Pipeline") {
                    numberedList([
                        "Analysis pass — FFmpeg's loudnorm filter measures integrated loudness, true peak, and loudness range.",
                        "Normalization pass — measured values are applied as a single linear gain. No dynamic processing; the stereo image and transients are unchanged.",
                        "MP3 encoding (if Output is MP3 or Both) — the normalized WAV is encoded with libmp3lame at the chosen bitrate."
                    ])
                    text("Output: 24-bit WAV at the chosen sample rate, and/or MP3.")
                }
                section("WaxOff — Settings") {
                    definition("Preset", "Applies a saved group of settings in one click. Three built-in presets are included; you can save your own via the Preset menu.")
                    definition("Sample Rate", "44.1 kHz or 48 kHz for the output WAV (and MP3 source).")
                    definition("Output", "WAV only, MP3 only, or both. WAV is always 24-bit PCM.")
                    definition("MP3 Bitrate", "CBR bitrate for MP3 output: 128, 160, or 192 kbps. Grayed out when Output is WAV only.")
                    definition("Phase Rotation", "Applies a 150 Hz all-pass filter before normalization. Improves headroom on material with bass-heavy phase issues. On by default.")
                    definition("True Peak", "Maximum true peak ceiling: −3.0 to −0.1 dBTP. −1.0 dBTP is the standard for podcast streaming platforms.")
                    definition("Target LUFS", "Integrated loudness target: −24 to −14 LUFS. −18 LUFS is the podcast standard; −16 LUFS gives a louder result.")
                    definition("Output Dir", "Where output files are saved. Defaults to the same folder as the source.")
                }
                section("WaxOff — Built-in Presets") {
                    definition("Podcast Standard", "−18 LUFS, −1.0 dBTP, Both WAV + MP3 at 160 kbps, 44.1 kHz. Correct for most podcast hosts.")
                    definition("Podcast Loud", "−16 LUFS, −1.0 dBTP, Both WAV + MP3 at 160 kbps, 44.1 kHz. Louder perceived volume, still within platform limits.")
                    definition("WAV Only (Mastering)", "−18 LUFS, −1.0 dBTP, WAV only at 48 kHz. For delivery to a mastering engineer or video platform.")
                    text("Save your own presets via the Preset menu › Save Current Settings…. Custom presets persist across relaunches and can be deleted from the same menu.")
                }

                dividerRow

                section("Supported Formats") {
                    text("WAV, AIFF, AIF, MP3, FLAC, M4A, OGG, Opus, CAF, WMA, AAC, MP4, MOV.")
                    text("All processing uses FFmpeg, bundled inside the app — no separate installation required.")
                }

                dividerRow

                section("Support") {
                    text("WaxOn/WaxOff is free. If it saves you time, a coffee is always appreciated.")
                    Button("Support on Ko-fi →") {
                        if let url = URL(string: "https://ko-fi.com/sevmo") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    Button("sevmorris.github.io →") {
                        if let url = URL(string: "https://sevmorris.github.io") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                }

                Spacer()
            }
            .padding(30)
        }
        .frame(width: 580, height: 720)
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WaxOn/WaxOff Help")
                .font(.largeTitle.bold())
            Text("Podcast Audio Prep for macOS")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var dividerRow: some View {
        Divider()
            .padding(.vertical, 4)
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
