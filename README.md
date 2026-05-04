# WaxOn / WaxOff
### Two-Mode Audio Engineering Utility for macOS

<p align="center">
  <strong>Podcast Audio Prep Utility</strong>
  <br />
  <strong>Version:</strong> 1.8
  <br />
  <a href="https://github.com/sevmorris/WaxOnWaxOff/releases/latest/download/WaxOnWaxOff-v1.8.dmg"><strong>Download</strong></a>
  ·
  <a href="https://sevmorris.github.io/WaxOnWaxOff/manual/">Manual</a>
  ·
  <a href="https://sevmorris.github.io/WaxOnWaxOff/manual/theory.html">Theory of Operation</a>
</p>

**WaxOn/WaxOff** is an internal utility designed to enforce signal integrity and loudness standards across a podcast production pipeline. It provides a standardized, two-stage workflow for preparing raw assets and finalizing distribution masters.

This tool was built to solve specific signal-to-noise and normalization challenges in freelance audio engineering. While developed for personal use, it is made publicly available for others who require a "zero-fluff" technical solution for voice-forward audio processing.

---

## I. WaxOn — Signal Conditioning (Prep)
*Use on raw recordings prior to non-destructive editing.*

* **High-Pass Filter:** Configurable cutoff (20–90 Hz) for HVAC/handling noise removal.
* **Noise Reduction:** Optional RNNoise (ML-based) suppression; best for steady-state background noise.
* **De-esser:** Optional gentle sibilance reduction.
* **Level Riding:** Optional downward-only `dynaudnorm` to tame loud outliers without lifting the noise floor.
* **Dynamic Leveling:** Optional bidirectional `dynaudnorm` for panel/multi-voice sources, with a Gentle→Aggressive responsiveness control.
* **Loudness Normalization:** Two-pass EBU R128 linear gain (dynamics fully preserved).
* **Floor Monitoring:** Estimated noise floor detection with color-coded warning badges.
* **Peak Control:** 2× oversampled true peak limiting (−1 to −3 dB ceiling).
* **Phase Alignment:** 200 Hz allpass filter to reduce peak asymmetry and maximize headroom.

**Output Logic:** `{name}-{rate}[ds-]waxon-{limit}.wav` (24-bit; `ds-` inserted when De-esser is on)

## II. WaxOff — Distribution Mastering
*Use on finished mixes to ensure broadcast compliance.*

* **EBU R128 Normalization:** Two-pass analysis + linear gain; no dynamic compression.
* **True Peak Management:** Configurable ceiling (−3.0 to −0.1 dBTP).
* **Multi-Format Delivery:** 24-bit WAV, CBR MP3 (up to 192 kbps), or simultaneous output.
* **Crest Factor Optimization:** Optional 150 Hz allpass for bass-heavy material.
* **Optional Pre-Norm Leveling:** Gentle `dynaudnorm` step before loudnorm for delivery sources whose macro-dynamics need tightening.

**Output Logic:** `{name}-lev-{target}LUFS.[wav/mp3]`

---

## Operational Specifications
* **Waveform Audit:** Real-time waveform preview with dB scaling.
* **Metadata Stats:** RMS, Peak, Crest Factor, Integrated LUFS, and Floor estimation.
* **Concurrency:** 3 simultaneous batch processing threads.
* **Environment:** macOS 14.0+ (Sonoma); Native Apple Silicon and Intel support.
* **Dependencies:** Bundled FFmpeg; no external installation required.

## Technical Origin
This utility is the result of a **Human-AI Collaboration**. 

I am an audio engineer, not a developer; these tools are built using AI-assisted coding to bridge that technical gap. I act as the **Architect and Executive Producer**, defining the audio signal chains and logic, while the code is generated through iterative stress-testing with Large Language Models. 

This is a personal toolset provided "as-is." It is designed for utility and precision, not as a commercial product.

---

### License
Copyright © 2026 Seven Morris.
Distributed under the [GNU General Public License v3.0](LICENSE).
