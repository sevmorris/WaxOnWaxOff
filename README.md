# WaxOn / WaxOff
### Two-Mode Audio Engineering Utility for macOS

<p align="center">
  <strong>Podcast Audio Prep Utility</strong>
  <br />
  <strong>Version:</strong> 1.12.3
  <br />
  <a href="https://github.com/sevmorris/WaxOnWaxOff/releases/latest/download/WaxOnWaxOff-v1.12.3.dmg"><strong>Download</strong></a>
  ·
  <a href="https://sevmorris.github.io/WaxOnWaxOff/">App Page</a>
  ·
  <a href="https://sevmorris.github.io/WaxOnWaxOff/manual/">Manual</a>
  ·
  <a href="https://sevmorris.github.io/WaxOnWaxOff/manual/theory.html">Theory of Operation</a>
</p>

**WaxOn/WaxOff** solves a specific problem: you receive a guest recording that's quiet, uneven, or sitting in a bed of room noise, and you need a clean, normalized WAV before you open your session. No import-normalize-export dance. No sending audio to a cloud service.

<p align="center">
  <img src="docs/images/waxon-waveform.png" width="49%" alt="WaxOn processing — waveform view" />
  <img src="docs/images/waxoff-complete.png" width="49%" alt="WaxOff — completed delivery" />
</p>

The app runs in two stages that map onto the two moments in podcast production where repetitive manual work otherwise lives:

- **WaxOn** runs before you edit. It conditions the raw file — high-pass filter, EBU R128 normalization with dynamics fully preserved. Output is a prep-ready 24-bit WAV named to stay sortable alongside the source in Finder without collision (e.g., `interview-44kwaxon-1dB.wav`).
- **WaxOff** runs after you bounce. It takes your finished mix to broadcast-compliant delivery — EBU R128 to target LUFS, true peak ceiling, WAV and/or MP3 output.

**Local processing:** No upload, no subscription, no audio leaving your machine. Transparent, inspectable signal chain.

**vs. iZotope RX:** Not a replacement for surgical repair — plosives, deep clicks, and spectral cleanup are still RX's job. But for the repetitive normalize → EQ → bounce work on clean-enough files, RX is overkill. WaxOn handles that stage in a single drop.

**vs. a bash script:** The two-stage model and the preset system. WaxOn presets encode your processing decisions so batches are repeatable. WaxOff presets capture your delivery spec per platform.

---

## I. WaxOn — Signal Conditioning (Prep)
*Use on raw recordings prior to non-destructive editing.*

* **High-Pass Filter:** Configurable cutoff (Off–90 Hz) for HVAC/handling noise removal. DC offset always removed.
* **Dynamic Leveling:** Optional bidirectional `dynaudnorm` (fixed moderate setting) for panel/multi-voice sources with inconsistent levels.
* **Loudness Normalization:** Two-pass EBU R128 linear gain (dynamics fully preserved).
* **Floor Monitoring:** Estimated noise floor detection with color-coded warning badges.
* **Peak Control:** 2× oversampled true peak limiting (−1 to −3 dB ceiling).
* **Phase Alignment:** 200 Hz allpass filter to reduce peak asymmetry and maximize headroom.

**Output Logic:** `{name}-{rate}waxon{ceiling}.wav` (24-bit; ceiling is e.g. `-1dB`)

## II. WaxOff — Distribution Mastering
*Use on finished mixes to ensure broadcast compliance.*

* **EBU R128 Normalization:** Two-pass analysis + linear gain; no dynamic compression.
* **True Peak Management:** Configurable ceiling (−3.0 to −0.1 dBTP).
* **Multi-Format Delivery:** 24-bit WAV, CBR MP3 (up to 192 kbps), or simultaneous output.

**Output Logic:** `{name}-lev{target}LUFS.[wav/mp3]` (target is e.g. `-18LUFS`)

---

## Operational Specifications
* **Waveform Audit:** Real-time waveform preview with dB scaling.
* **Metadata Stats:** RMS, Peak, Crest Factor, Integrated LUFS, and Floor estimation.
* **Concurrency:** Adaptive batch processing — scales with available CPU cores.
* **Environment:** macOS 14.0+ (Sonoma); Native Apple Silicon and Intel support.
* **Dependencies:** Bundled FFmpeg; no external installation required.

## Technical Origin
I designed the signal chain and DSP parameters. The Swift implementation was built with AI assistance. The audio processing logic — two-pass loudnorm per the FFmpeg spec, ITU-R BS.1770-compliant K-weighting, and internal per-channel RNNoise on the analysis pass for measurement accuracy on noisy recordings — reflects deliberate choices, not defaults.

---

### Support
If WaxOn/WaxOff saves you time, [buy me a coffee](https://ko-fi.com/sevmo). Free forever either way.

### License
Copyright © 2026 Seven Morris.
Distributed under the [GNU General Public License v3.0](LICENSE).
