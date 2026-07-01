# WaxOn / WaxOff
### Two-Mode Audio Engineering Utility for macOS

<p align="center">
  <strong>Podcast Audio Prep Utility</strong>
  <br />
  <strong>Version:</strong> 2.2.0
  <br />
  <a href="https://github.com/sevmorris/WaxOnWaxOff/releases/latest/download/WaxOnWaxOff-v2.2.0.dmg"><strong>Download Latest (DMG)</strong></a>
  ·
  <a href="https://sevmorris.github.io/WaxOnWaxOff/">App Page</a>
  ·
  <a href="https://sevmorris.github.io/WaxOnWaxOff/manual/">Manual</a>
  ·
  <a href="https://sevmorris.github.io/WaxOnWaxOff/manual/theory.html">Theory of Operation</a>
  ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

**WaxOn/WaxOff** solves a specific problem: you receive a guest recording that's quiet, uneven, or poorly leveled, and you need a consistent prep WAV before you open your session—or a finished mix normalized to your delivery spec. No import-normalize-export dance. No sending audio to a cloud service.

WaxOn **conditions** level and dynamics (high-pass, optional dynamic leveling, optional EBU R128 gain, true-peak control). It does **not** apply spectral noise reduction to the output file. When Loudness Norm is enabled, RNNoise runs only on an internal analysis pass so loudness measurement isn't skewed by room tone—not as a user-facing denoise stage. For plosives, clicks, and heavy noise, use a repair tool (e.g. iZotope RX) before WaxOn.

The app runs in two stages that map onto the two moments in podcast production where repetitive manual work otherwise lives:

- **WaxOn** runs before you edit. It conditions the raw file — high-pass filter, optional EBU R128 normalization (dynamics fully preserved), and true-peak control to a fixed −1.0 dBTP ceiling — a 2× oversampled limiter when Loudness Norm is on, downward-only linear peak normalization when off. Output is a prep-ready 24-bit WAV named to stay sortable alongside the source in Finder (e.g., `interview-44kwaxon.wav`).
- **WaxOff** runs after you bounce. It takes your finished mix to broadcast-compliant delivery — EBU R128 to target LUFS, true peak ceiling, WAV and/or MP3 output.

**Local processing:** No upload, no subscription, no audio leaving your machine. Transparent, inspectable signal chain.

**vs. iZotope RX:** Not a replacement for surgical repair — plosives, deep clicks, and spectral cleanup are still RX's job. But for the repetitive normalize → EQ → bounce work on clean-enough files, RX is overkill. WaxOn handles that stage in a single drop.

**vs. a bash script:** The two-stage model and the preset system. WaxOn presets encode your processing decisions so batches are repeatable. WaxOff presets capture your delivery spec per platform.

---

## I. WaxOn — Signal Conditioning (Prep)
*Use on raw recordings prior to non-destructive editing.*

* **High-Pass Filter:** On (80 Hz) or Off (20 Hz DC floor). DC offset always removed.
* **Dynamic Leveling:** Optional `dynaudnorm` with adjustable aggressiveness (Gentle → Aggressive) for panel/multi-voice sources with inconsistent levels.
* **Loudness Normalization:** Optional two-pass EBU R128 linear gain (dynamics fully preserved; default off). RNNoise may run on an analysis-only temp when this is on—see [Theory of Operation](https://sevmorris.github.io/WaxOnWaxOff/manual/theory.html)—not on the exported WAV.
* **Floor Monitoring:** Estimated noise floor detection with color-coded warning badges.
* **Peak Control:** True peak held to a fixed −1.0 dBTP ceiling — 2× oversampled limiting when Loudness Norm is on; downward-only linear peak normalization (transparent when the source is already under ceiling) when off.
* **Phase Alignment:** Optional 200 Hz allpass filter to reduce peak asymmetry and maximize headroom (default on).

**Output Logic:** `{name}-{44k|48k}waxon.wav` (24-bit)

## II. WaxOff — Broadcast Delivery
*Use on finished mixes to ensure broadcast compliance.*

* **EBU R128 Normalization:** Two-pass analysis + linear gain; no dynamic compression.
* **True Peak Management:** Configurable ceiling (−3.0 to −0.5 dBTP).
* **Multi-Format Delivery:** 24-bit WAV, CBR MP3 (up to 192 kbps), or simultaneous output.
* **Mono Delivery:** Optional true single-channel output for mono sources (defaults to dual-mono stereo); never downmixes a stereo source.

**Output Logic:** `{name}-lev{target}LUFS.[wav/mp3]` (target is e.g. `-18LUFS`)

---

## Operational Specifications
* **Waveform Audit:** Real-time waveform preview with dB scaling.
* **Metadata Stats:** RMS, Peak, Crest Factor, Integrated LUFS, and Floor estimation.
* **Concurrency:** Adaptive batch processing — scales with available CPU cores.
* **Environment:** macOS 14.0+ (Sonoma) on **Apple Silicon (M-series) Macs** (arm64). Intel Macs are not supported.
* **Dependencies:** Bundled FFmpeg; no external installation required.

### Security model
The app ships with **App Sandbox disabled** so it can launch the bundled `ffmpeg` and `ffprobe` binaries via `Process()` (sandboxed apps cannot exec non-sandboxed helpers). That means the app can read and write anywhere your user account can once you grant a path through drag-and-drop or the file picker—same trust model as a typical command-line tool. Download builds from the [official releases](https://github.com/sevmorris/WaxOnWaxOff/releases) only; `release.sh` codesigns and notarizes the DMG. See `WaxOnWaxOff/WaxOnWaxOff.entitlements` for the documented rationale.

## Building from Source

```bash
git clone https://github.com/sevmorris/WaxOnWaxOff.git
cd WaxOnWaxOff
open WaxOnWaxOff.xcodeproj
```

Xcode runs `scripts/fetch-ffmpeg.sh` automatically before each build, so the very first build will pull pinned `ffmpeg` and `ffprobe` (~100 MB combined) from a [GitHub release asset](https://github.com/sevmorris/WaxOnWaxOff/releases/tag/ffmpeg-deps-8.0-arm64) and verify SHA-256s. You can also run the script standalone for CI or to re-verify checksums. See `Vendor/README.md` for the manifest and update instructions.

## Technical Origin
I designed the signal chain and DSP parameters. The Swift implementation was built with AI assistance. The audio processing logic — two-pass loudnorm per the FFmpeg spec, ITU-R BS.1770-compliant K-weighting, and internal per-channel RNNoise on the loudnorm analysis pass (WaxOn, when Loudness Norm is enabled) for measurement accuracy on noisy recordings — reflects deliberate choices, not defaults.

---

### Support
If WaxOn/WaxOff saves you time, [buy me a coffee](https://ko-fi.com/sevmo). Free forever either way.

### License
Copyright © 2026 Seven Morris.
Distributed under the [GNU General Public License v3.0](LICENSE).

Bundled FFmpeg binaries and RNNoise model: see [`Vendor/README.md`](Vendor/README.md) for version, checksums, and GPL source offer.
