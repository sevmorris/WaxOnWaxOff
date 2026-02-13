# WaxOn

**Podcast Audio Prep for macOS**

WaxOn prepares raw podcast recordings for editing in a DAW. It handles high-pass filtering, loudness normalization, phase rotation, and brick-wall limiting in a single drag-and-drop workflow, outputting 24-bit WAV files.

WaxOn does not perform noise reduction, de-essing, or any other restoration — it's a first-step ingest processor that gets your raw recordings into a consistent, workable format before further prep or editing.

## Features

- **High-Pass Filter**: Configurable cutoff (20–150 Hz, default 70 Hz) removes DC offset, low-frequency rumble, and handling noise
- **Loudness Normalization**: Optional two-pass EBU R128 normalization with configurable target (-35 to -16 LUFS, default -30). Uses linear gain for transparent level matching across files
- **Brick-Wall Limiting**: Configurable ceiling (-6 to -0.1 dB) to tame wild transients
- **True Peak Limiting**: Optional oversampled limiting (up to 8x) to catch inter-sample peaks
- **Phase Rotation**: Optional 150 Hz allpass filter to reduce crest factor and improve headroom
- **Mono or Stereo Output**: Mono with left/right channel selection, or stereo passthrough
- **Sample Rate Conversion**: 44.1 kHz or 48 kHz output
- **Drag & Drop**: Drop audio files onto the window to process
- **Batch Processing**: Process multiple files at once

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
5. Output files are saved alongside the originals with a `-waxon` suffix

## Output Naming

```
{original-name}-{samplerate}waxon-{limit}dB.wav
```

Example: `episode-01-44kwaxon-1dB.wav`

## Advanced Settings

- **High Pass**: High-pass filter cutoff frequency (default 70 Hz, range 20–150 Hz)
- **True Peak**: Enable oversampled peak detection
- **Oversample**: Oversampling factor for true peak limiting (1–8x)
- **Loudness Norm**: Enable EBU R128 loudness normalization
- **Target**: Integrated loudness target (default -30 LUFS, range -35 to -16 LUFS)
- **Phase Rotate**: 150 Hz allpass filter for crest factor reduction

## Processing Pipeline

WaxOn uses FFmpeg with a multi-pass pipeline:

1. **High-pass filtering**, channel selection (if mono), phase rotation (if enabled), and resampling to target sample rate
2. **Loudness normalization** (if enabled) — two-pass EBU R128 analysis followed by linear gain application
3. **Brick-wall limiting** with optional oversampling for true peak control

Output format: 24-bit WAV

## License

Copyright © 2026 Seven Morris

This program is free software: you can redistribute it and/or modify it under the terms of the [GNU General Public License v3.0](LICENSE).
