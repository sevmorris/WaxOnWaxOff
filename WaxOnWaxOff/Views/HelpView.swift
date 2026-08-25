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
                    WaxOn/WaxOff is a podcast audio tool for macOS. It has two modes. It \
                    operates on Apple Silicon (M-series) Macs. Both modes use the same file \
                    workflow, waveform viewer, and stats panel. The two modes are different in \
                    what they do to your audio.
                    """)
                    text("""
                    You can change the mode at any time. Use the WaxOn and WaxOff buttons \
                    in the top left of the window. Each mode keeps its own file list. A change \
                    of mode does not disturb your work in the other mode.
                    """)
                }

                section("The File List Bar") {
                    text("""
                    A bar is below the file list. It holds the controls for the list and for \
                    the selected rows. The toolbar at the top of the window holds only the \
                    controls that apply to all the files.
                    """)
                    definition("+", "A dialog opens. Select one file, more than one file, or a folder. Click Add. The dialog accepts the same files as a drag. WaxOn/WaxOff scans a folder and its subfolders for supported audio files. This button stays available while a batch runs.")
                    definition("−", "This button removes the selected rows from the list. It is available only when you select one row or more. It is not available while a batch runs. You can also press Delete.")
                    definition("Metadata", "WaxOff only. A sheet opens for the selected file. Refer to WaxOff — Episode Metadata below.")
                    definition("Clear All", "This button removes all the rows from the list. It is not available while a batch runs. You can also press Command-Option-Delete.")
                    text("""
                    The buttons show their names when the file list is wide. If you make the \
                    list narrow, the buttons show only their icons. Put the pointer on a \
                    button to see its name.
                    """)
                }

                dividerRow

                section("WaxOn — Raw Recording Prep") {
                    text("""
                    Use WaxOn on your raw recordings before you edit them. WaxOn removes \
                    low-frequency rumble. WaxOn controls the peak level. WaxOn can also \
                    normalize the loudness. The output is a 24-bit WAV file for Logic Pro or a \
                    different editor. WaxOn does not remove noise from the output file. For \
                    more data, refer to the online Theory of Operation.
                    """)
                }
                section("WaxOn — Quick Start") {
                    steps([
                        "Set the sample rate and the output channels in Settings. The toggles and the knobs are in the control bar.",
                        "Drag your audio files onto the window or onto the file list. As an alternative, click the plus button in the bar below the file list.",
                        "Click Process. WaxOn writes the output files to the folder of the source files."
                    ])
                }
                section("WaxOn — Output Naming") {
                    code("{original-name}-{44k|48k}waxon.wav")
                    text("Example: interview-44kwaxon.wav")
                }
                section("WaxOn — Processing Pipeline") {
                    numberedList([
                        "High-pass filter. On uses 80 Hz. Off uses a 20 Hz DC floor. WaxOn always removes the DC offset.",
                        "Channel handling. Mono extracts the left channel or the right channel. Mono downmixes a multichannel source. Stereo sends the two channels of a stereo source through with no change. Split L/R runs the pipeline once per channel and writes two mono files. For a different channel count, FFmpeg converts the source to two channels with its default matrix. The app writes a warning to the console.",
                        "Phase rotation is optional. It is a 200 Hz allpass filter. The default is on.",
                        "WaxOn resamples the audio to the target sample rate.",
                        "Dynamic Leveling is optional. It uses dynaudnorm. Use it for panel recordings and multi-voice sources. Do not use it for a solo voice.",
                        "Loudness normalization is optional. WaxOn measures integrated loudness once with EBU R128, then applies one constant gain to reach the target. Edit prep does not need a delivery-grade two-pass normalizer.",
                        "Peak control is always on. When Loudness Norm is on, a brick-wall limiter holds samples at −1.0 dBFS. When Loudness Norm is off, WaxOn measures the true peak and applies downward-only normalization to −1.0 dBTP. WaxOff enforces the strict true-peak ceiling at delivery."
                    ])
                    text("Output: 24-bit WAV.")
                }
                section("WaxOn — Settings") {
                    definition("Sample Rate", "Select 44.1 kHz or 48 kHz. Use the same value as your DAW project.")
                    definition("Channels", "Select Mono, Stereo, or Split L/R. Mono extracts one channel. Stereo sends the two channels of a stereo source through with no change. Split L/R is for a file holding two microphones with a different speaker on each channel: WaxOn preps each channel separately and writes two mono files, tagged -L- and -R-, so each speaker lands at a consistent level. Split L/R needs a two-channel source; anything else is written as one mono file with a warning. For a different channel count in Mono or Stereo, FFmpeg converts the source with its default matrix and the app writes a warning to the console.")
                    definition("Source Channel", "Select Left or Right. This is the channel that WaxOn extracts in Mono mode.")
                    definition("High Pass", "On uses 80 Hz. It removes rumble and proximity-effect bass. Off uses a 20 Hz DC floor only. WaxOn always removes the DC offset.")
                    definition("Phase Rotation", "WaxOn applies a 200 Hz allpass filter before normalization. The filter reduces the crest factor on asymmetric voice recordings. This gives 1–4 dB more headroom before the limiter. You cannot hear an effect on the audio character. The default is on.")
                    definition("Dynamic Leveling", "This setting turns on dynaudnorm. It increases the level of quiet voices. It decreases the level of loud voices. Use it for panel recordings, live Q&As, or multi-guest interviews. Do not use it for a solo voice. Strength controls the speed and the quantity of the adjustment.")
                    definition("Loudness Norm", "This setting turns on EBU R128 loudness normalization. When it is off, WaxOn applies only the filters and downward-only peak normalization.")
                    definition("Target", "This is the integrated loudness target when Loudness Norm is on. The default is −30 LUFS. The range is −35 to −16 LUFS. A lower value gives more headroom for editing.")
                    definition("Output Dir", "This is the folder for the output files. The default is the folder of the source file.")
                }

                dividerRow

                section("WaxOff — Delivery & Mastering") {
                    text("""
                    Use WaxOff on your finished mix. WaxOff applies broadcast-standard EBU \
                    R128 loudness normalization. WaxOff delivers the result as a 24-bit WAV \
                    file, an MP3 file, or both. You can then upload the files to your podcast \
                    host.
                    """)
                }
                section("WaxOff — Quick Start") {
                    steps([
                        "Select a preset from the menu in the header. As an alternative, set your own values.",
                        "Drag your finished mix file onto the window. As an alternative, click the plus button in the bar below the file list.",
                        "Click Process. WaxOff writes the output files to the folder of the source file."
                    ])
                }
                section("WaxOff — Output Naming") {
                    code("{original-name}-lev{target}LUFS.wav / .mp3")
                    text("Example: episode-42-final-lev-18LUFS.wav")
                }
                section("WaxOff — Processing Pipeline") {
                    numberedList([
                        "Analysis pass. The audio goes through a 200 Hz allpass filter for phase rotation. The audio then goes through the FFmpeg loudnorm filter. The loudnorm filter measures the integrated loudness, the true peak, and the loudness range. If you do not select Mono delivery, WaxOff upmixes a mono source to dual-mono stereo. The upmix occurs at the start of the chain, before the allpass filter.",
                        "Normalization pass. The same chain runs again with the measured values and one linear gain. The 200 Hz allpass filter runs here also. Thus the output agrees with the measurement. In linear mode there is no dynamic processing. The stereo image and the transients do not change. WaxOff uses a fixed internal loudness range of 9 LU. If the loudness range of the mix is more than 9 LU, loudnorm applies dynamic normalization instead. If a linear gain would go past the true-peak ceiling, loudnorm also applies dynamic normalization instead. The result is below the target and has a smaller loudness range.",
                        "Brick-wall limiter. This is a 2× oversampled true-peak limiter at your True Peak ceiling. It catches the inter-sample peaks that the loudnorm linear mode did not find. On a well-mixed source the limiter does not operate.",
                        "MP3 encoding occurs when Output is MP3 or Both. WaxOff encodes the normalized WAV file with libmp3lame at the selected bitrate. A separate limiter operates before the encoder. This limiter is 1 dB below your True Peak. It absorbs the overshoot from the lossy decode. The MP3 sample rate is always 44.1 kHz.",
                        "Verification. WaxOff measures each delivered file again. This is a check of the result. It is not a second processing stage. The audio on disk is complete before this starts, and each row shows Complete while it runs. The toolbar shows the progress and gives you a Stop verifying button. You can also start the next batch during the verification. WaxOff does not change a delivered file after it writes the file."
                    ])
                    text("Output: a 24-bit WAV file at the selected sample rate, an MP3 file, or both. The default is stereo. If you select Mono delivery for a mono source, the output has one channel.")
                }
                section("WaxOff — Settings") {
                    definition("Preset", "A preset applies a saved group of settings with one click. The app includes three built-in presets. You can save your own presets from the Preset menu.")
                    definition("Sample Rate", "Select 44.1 kHz or 48 kHz for the output WAV file. WaxOff always encodes MP3 at 44.1 kHz. This setting has no effect on the MP3 file. The control is not available when Output is MP3 only.")
                    definition("Output", "Select WAV only, MP3 only, or both. The WAV file is always 24-bit PCM.")
                    definition("Channels", "Select Mono or Stereo delivery for mono sources. Stereo is the default. Stereo upmixes a mono source to dual-mono stereo. Mono delivers one channel. The control is available only when all the loaded sources are mono. WaxOff does not downmix a stereo source.")
                    definition("MP3 Bitrate", "Select the CBR bitrate for the MP3 output: 128, 160, or 192 kbps. The control is not available when Output is WAV only.")
                    definition("True Peak", "This is the maximum true-peak ceiling. The range is −3.0 to −0.5 dBTP. Podcast streaming platforms use −1.0 dBTP as the standard.")
                    definition("Target LUFS", "This is the integrated loudness target. The range is −24 to −14 LUFS. The podcast standard is −18 LUFS. A value of −16 LUFS gives a louder result.")
                    definition("Output Dir", "This is the folder for the output files. The default is the folder of the source file.")
                }
                section("WaxOff — Built-in Presets") {
                    definition("Podcast Standard", "−18 LUFS, −1.0 dBTP, WAV and MP3 at 160 kbps, 44.1 kHz. Use this preset for most podcast hosts.")
                    definition("Podcast Loud", "−16 LUFS, −1.0 dBTP, WAV and MP3 at 160 kbps, 44.1 kHz. The perceived volume is louder. The result stays in the platform limits.")
                    definition("WAV Only (Mastering)", "−18 LUFS, −1.0 dBTP, WAV only at 48 kHz. Use this preset to deliver to a mastering engineer or a video platform.")
                    text("To save your own preset, use the Preset menu › Save Current Settings…. Custom presets stay available after you restart the app. To delete a custom preset, use Manage Presets… in the same menu.")
                }
                section("WaxOff — Episode Metadata") {
                    text("""
                    WaxOff can write podcast metadata into a delivered MP3 file. Select one \
                    file in the list. Click Metadata in the bar below the file list. A sheet \
                    opens for that file. The Metadata button is available only when exactly \
                    one file is selected. The button is not available while a batch delivers. \
                    The button stays available during the verification.
                    """)
                    text("""
                    Metadata applies to MP3 output only. WaxOff writes the episode metadata \
                    into the MP3 file. The WAV file keeps only the metadata of the source \
                    file. The sheet shows a notice when the output mode writes no MP3. \
                    Metadata belongs to one file. A preset does not keep metadata. Settings \
                    does not keep metadata. WaxOff writes the tags as ID3v2.3.
                    """)
                    definition("Podcast Name", "This is the name of the show. WaxOff writes it as the ID3 album tag.")
                    definition("Episode Title", "This is the title of the episode. WaxOff writes it as the ID3 title tag. Leave the field empty to use the name of the delivered file without the file extension. The placeholder in the field shows that name. The name includes the loudness suffix. Thus it is not the same as the name of the source file. All the earlier versions do the same.")
                    definition("Artwork", "Use a PNG or JPEG image for the front cover. Drag one image onto the artwork area, or click Choose…. If you drag a different type of file, WaxOff refuses it and shows the reason. Apple Podcasts asks for a square image from 1400 to 3000 pixels. The sheet shows a note for a different shape or size. The note is advice only. WaxOff delivers the file in all conditions.")
                    definition("Chapters", "The chapter table is first. Each row is one chapter. Edit the time in the first field. Edit the title in the second field. Click the minus button to remove that chapter. Click Add Chapter to add a chapter. The paste box is below the table. Paste one chapter on each line. Use MM:SS Title or HH:MM:SS Title. The table and the box always show the same chapters.")
                    text("""
                    Each chapter time must be later than the time before it. No chapter time \
                    can be at or after the end of the audio. Each chapter must have a title. \
                    An error message names the line that is not correct. The Save button is \
                    not available while an error message shows.
                    """)
                    text("""
                    A tag badge shows on the row of a file that has metadata. Put the pointer \
                    on the badge to see what the file has. The badge stays after the \
                    delivery.
                    """)
                    text("""
                    WaxOff does not write an episode description. The RSS feed of your podcast \
                    supplies the description to the podcast apps.
                    """)
                }

                dividerRow

                section("Supported Formats") {
                    text("WAV, AIFF, AIF, AIFC, MP3, FLAC, M4A, CAF, AAC, MP4, MOV.")
                    text("All processing uses FFmpeg. FFmpeg is included in the app. You do not install it separately.")
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
