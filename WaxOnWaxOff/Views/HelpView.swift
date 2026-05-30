import SwiftUI

// Orange/cream palette — matches docs/index.html and the app accent so the help
// window reads as part of the same product, not a generic system document.
/// Warm dark background (#1A1816) — same as the landing page.
private let helpSurface   = Color(red: 0x1A/255, green: 0x18/255, blue: 0x16/255)
/// Cream body text (#F2EAD8) — readable on the dark warm surface.
private let helpText      = Color(red: 0xF2/255, green: 0xEA/255, blue: 0xD8/255)
/// Orange accent (#D4520A) — section headings, matches app accent.
private let helpAccent    = Color(red: 0xD4/255, green: 0x52/255, blue: 0x0A/255)
/// Muted tan for subtitle / definition detail.
private let helpSecondary = Color(red: 0x9C/255, green: 0x8A/255, blue: 0x6A/255)

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                section("Overview") {
                    text("""
                    WaxOn/WaxOff is a two-mode podcast audio tool for macOS on Apple Silicon \
                    (M-series) Macs. Both modes share the same drag-and-drop file workflow, \
                    waveform viewer, and stats panel — they differ in what they do to your audio.
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
                        "Set sample rate and output channels in Settings; toggles and knobs are in the control bar.",
                        "Drag audio files onto the window (or the file list).",
                        "Click Process. Output files appear alongside the originals."
                    ])
                }
                section("WaxOn — Output Naming") {
                    code("{original-name}-{44k|48k}waxon.wav")
                    text("Example: interview-44kwaxon.wav")
                }
                section("WaxOn — Processing Pipeline") {
                    numberedList([
                        "High-pass filter — On (80 Hz) or Off (20 Hz DC floor). DC offset always removed.",
                        "Channel handling — mono extracts left/right (or downmixes multichannel sources); stereo passes both channels through.",
                        "Optional phase rotation — 200 Hz allpass (default on).",
                        "Resampling to the target sample rate.",
                        "Dynamic leveling (if enabled) — dynaudnorm for panel recordings and multi-voice sources. Not recommended for solo voice.",
                        "Loudness normalization (if enabled) — two-pass EBU R128 analysis, then linear gain. Pass 1 may use internal RNNoise for measurement accuracy only.",
                        "Brick-wall limiting — always on; 2× oversampled true peak control at fixed −1.0 dBTP."
                    ])
                    text("Output: 24-bit WAV.")
                }
                section("WaxOn — Settings") {
                    definition("Sample Rate", "44.1 kHz or 48 kHz. Match your DAW project setting.")
                    definition("Output", "Mono or Stereo. Mono extracts a single channel; Stereo passes both channels through unchanged.")
                    definition("Channel", "Left or Right — which channel to extract in Mono mode.")
                    definition("High Pass", "On (80 Hz) removes rumble and proximity-effect bass; Off uses a 20 Hz DC floor only. DC offset is always removed.")
                    definition("Phase Rotation", "Applies a 200 Hz all-pass filter before normalization. Reduces crest factor on asymmetric voice recordings, recovering 1–4 dB of headroom before the limiter. Effect on audio character is inaudible. On by default.")
                    definition("Dynamic Leveling", "Enables dynaudnorm. Lifts quiet voices and tames loud ones. Best for panel recordings, live Q&As, or multi-guest interviews — not for regular solo voice use. Aggressiveness controls how quickly and strongly the leveling responds.")
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
                    code("{original-name}-lev{target}LUFS.wav / .mp3")
                    text("Example: episode-42-final-lev-18LUFS.wav")
                }
                section("WaxOff — Processing Pipeline") {
                    numberedList([
                        "Analysis pass — FFmpeg's loudnorm filter measures integrated loudness, true peak, and loudness range.",
                        "Normalization pass — measured values are applied as a single linear gain. No dynamic processing; the stereo image and transients are unchanged.",
                        "MP3 encoding (if Output is MP3 or Both) — the normalized WAV is encoded with libmp3lame at the chosen bitrate."
                    ])
                    text("Output: 24-bit WAV at the chosen sample rate, and/or MP3. Always stereo — mono sources are upmixed to dual-mono.")
                }
                section("WaxOff — Settings") {
                    definition("Preset", "Applies a saved group of settings in one click. Three built-in presets are included; you can save your own via the Preset menu.")
                    definition("Sample Rate", "44.1 kHz or 48 kHz for the output WAV (and MP3 source).")
                    definition("Output", "WAV only, MP3 only, or both. WAV is always 24-bit PCM.")
                    definition("MP3 Bitrate", "CBR bitrate for MP3 output: 128, 160, or 192 kbps. Grayed out when Output is WAV only.")
                    definition("True Peak", "Maximum true peak ceiling: −3.0 to −0.5 dBTP. −1.0 dBTP is the standard for podcast streaming platforms.")
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
                    text("WAV, AIFF, AIF, AIFC, MP3, FLAC, M4A, OGG, Opus, CAF, WMA, AAC, MP4, MOV.")
                    text("All processing uses FFmpeg, bundled inside the app — no separate installation required.")
                }

                dividerRow

                VStack(alignment: .leading, spacing: 6) {
                    Text("If WaxOn/WaxOff saves you time, consider buying me a coffee.")
                        .foregroundColor(helpText)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("ko-fi.com/sevmo", destination: URL(string: "https://ko-fi.com/sevmo")!)
                        .font(.body)
                        .foregroundColor(helpAccent)
                }

                Spacer()
            }
            .padding(30)
        }
        .frame(width: 580, height: 720)
        .background(helpSurface)
        .preferredColorScheme(.dark)
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WaxOn/WaxOff Help")
                .font(.largeTitle.bold())
                .foregroundColor(helpText)
            Text("Podcast Audio Prep for macOS")
                .font(.title3)
                .foregroundColor(helpSecondary)
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
                .foregroundColor(helpAccent)
            content()
        }
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .foregroundColor(helpText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func code(_ string: String) -> some View {
        Text(string)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(helpText)
            .padding(8)
            .background(Color(red: 0x24/255, green: 0x20/255, blue: 0x18/255))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.body.bold())
                        .foregroundColor(helpAccent)
                        .frame(width: 20, alignment: .trailing)
                    Text(item)
                        .foregroundColor(helpText)
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
                .foregroundColor(helpText)
            Text(detail)
                .foregroundColor(helpSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

#Preview {
    HelpView()
}
