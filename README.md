<p align="center">
  <img src="assets/waxon_banner.png" alt="WaxOn">
</p>

**Podcast Audio Prep for macOS**

WaxOn prepares raw podcast recordings for editing in a DAW. It handles high-pass filtering, loudness normalization, phase rotation, and brick-wall limiting in a single drag-and-drop workflow, outputting 24-bit WAV files.

WaxOn does not perform noise reduction, de-essing, or any other restoration — it's a first-step ingest processor that gets your raw recordings into a consistent, workable format before further prep or editing.

## Design Philosophy

WaxOn is intentionally minimal. It does one thing — prepares raw podcast recordings for editing — and exposes only the controls that matter for that job. Sensible defaults handle the rest. Drop your files in, hit Process, and get to editing.

## Download

**[WaxOn v2.3 (DMG)](https://github.com/sevmorris/WaxOn/releases/latest/download/WaxOn-v2.3.dmg)**

> ⚠️ **Important — Read Before First Launch**
>
> macOS will block the app with a malware warning because it is not notarized with Apple. After mounting the DMG and dragging WaxOn to Applications, **you must run this command in Terminal:**
>
> ```
> xattr -cr /Applications/WaxOn.app
> ```
>
> Without this step, macOS will refuse to open the app.

## Features

- **High-Pass Filter**: Configurable cutoff (40–90 Hz, default 80 Hz) removes low-frequency rumble and handling noise
- **Loudness Normalization**: Optional two-pass EBU R128 normalization with configurable target (-35 to -16 LUFS, default -30). Uses linear gain for transparent level matching across files. True peak target respects your ceiling setting.
- **Brick-Wall Limiting**: Configurable ceiling (-3 to -1 dB) with 2x oversampled true peak limiting
- **Phase Rotation**: Automatic 200 Hz allpass to reduce peak asymmetry and improve headroom
- **Mono or Stereo Output**: Mono with left/right channel selection, or stereo passthrough
- **Sample Rate Conversion**: 44.1 kHz or 48 kHz output
- **Drag & Drop**: Drop audio files onto the window to process
- **Batch Processing**: Process multiple files in parallel (up to 3 concurrent jobs) with per-file progress
- **Input Validation**: Unsupported file formats are rejected automatically
- **File Reordering**: Drag to reorder files in the processing queue
- **Custom Output Directory**: Optionally set a dedicated output folder
- **Reveal in Finder**: Click to reveal processed output files
- **Waveform Preview**: Select a file to view its waveform with dB scale

## System Requirements

- macOS 14.0 (Sonoma) or later
- FFmpeg (bundled or installed via Homebrew)

## Usage

1. Launch WaxOn
2. Configure your settings:
   - **Sample Rate**: 44.1 kHz or 48 kHz
   - **Output**: Mono or Stereo
   - **Channel** (mono only): Left or Right from stereo source
   - **Limiter**: Ceiling level (e.g., -1.0 dB)
3. Drag and drop audio files onto the window
4. Click "Process"
5. Output files are saved alongside the originals with a `-waxon` suffix (or to your configured output directory)

## Output Naming

```
{original-name}-{samplerate}waxon-{limit}dB.wav
```

Example: `episode-01-44kwaxon-1dB.wav`

## Additional Settings

- **High Pass**: High-pass filter cutoff frequency (default 80 Hz, range 40–90 Hz)
- **Loudness Norm**: Enable EBU R128 loudness normalization
- **Target**: Integrated loudness target (default -30 LUFS, range -35 to -16 LUFS)
- **Output Directory**: Set a custom output folder (default: saves alongside source files)

## Processing Pipeline

WaxOn uses FFmpeg with a multi-pass pipeline:

1. **High-pass filtering**, channel selection (if mono), phase rotation, and resampling to target sample rate
2. **Loudness normalization** (if enabled) — two-pass EBU R128 analysis followed by linear gain application
3. **Brick-wall limiting** with 2x oversampled true peak control

Output format: 24-bit WAV

## Companion App

[WaxOff](https://github.com/sevmorris/WaxOff) finalizes your podcast mix for distribution — EBU R128 loudness normalization, optional phase rotation, and MP3 encoding.

**Workflow**: Raw recordings → **WaxOn** → Edit in DAW → **WaxOff** → Distribute

## License

Copyright © 2026. This app was designed and directed by Seven Morris, with code primarily generated through AI collaboration using [OpenClaw](https://openclaw.ai) and Claude (Anthropic).

This program is free software: you can redistribute it and/or modify it under the terms of the [GNU General Public License v3.0](LICENSE).

## A Note on AI

I'm a freelance audio engineer, not a software developer. These tools exist because AI made it possible for me to build things I couldn't build alone. It's exciting, but complicated.

The app icon is my own — hand-drawn. AI can build the software, but I can still make the art myself, and I think that's worth doing, even if poorly.

AI-assisted development raises real questions about labor displacement, resource consumption, and the concentration of power in a handful of tech companies. I don't have clean answers. I do think it matters that the people using these tools are honest about the trade-offs rather than pretending they don't exist.
