# Vendor dependencies

## FFmpeg / ffprobe (bundled binaries)

WaxOnWaxOff bundles a **static, audio-only FFmpeg 8.0** for macOS **arm64 (Apple Silicon only)**, built from a committed recipe in this repository. The binaries are **not** stored in git (~44 MB combined). Instead:

| Artifact | Location |
|----------|----------|
| Build recipe (Corresponding Source) | `scripts/build-ffmpeg.sh` |
| Binary checksums & release tag | `Vendor/ffmpeg-manifest.env` |
| Download script | `scripts/fetch-ffmpeg.sh` |
| GitHub release assets | Tag from manifest |

Xcode runs `scripts/fetch-ffmpeg.sh` before each build; `release.sh` runs it before packaging.

**Do not delete** the `ffmpeg-deps-*` GitHub releases — CI and fresh clones fetch binaries from them, and older tags remain the corresponding artifact for previously released app versions.

### The build

`scripts/build-ffmpeg.sh` builds FFmpeg 8.0 against LAME 3.100, both pinned and SHA-256 verified, with **no `--enable-gpl`**, **no `--enable-nonfree`**, **no `--enable-version3`**, and no video or image external libraries. The only external library is `libmp3lame`, for MP3 encoding. The script asserts, fail-closed, that the resulting binaries execute, carry none of those three flags, link `libmp3lame`, target the project's deployment target, and have **no non-system dynamic dependencies**. Execution is asserted *before* the flag checks — a binary that cannot run emits no configuration string, and every "flag absent" assertion would otherwise pass vacuously.

Two flags are load-bearing and documented inline in the script: `-fno-stack-check` (macOS clang codegen workaround) and `-ffp-contract=off` (FMA contraction varies by compiler version and accumulates through IIR biquad feedback paths; disabling it makes filter output depend on the source rather than on the toolchain).

### License

| Field | Value |
|-------|--------|
| Upstream release | **FFmpeg 8.0** (“Huffman”), released 2025-08-22 |
| Source archive | https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz |
| PGP signature | https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz.asc |
| FFmpeg license | **LGPL-2.1-or-later** (no `--enable-gpl`; verified at `LICENSE.md:3-6` of the pinned source) |
| LAME 3.100 | **LGPL-2.0-or-later** — https://lame.sourceforge.io/ (GNU *Library* GPL v2 "or later"; verified at `include/lame.h:6-9`) |

**No GPL components.** x264, x265 and libvidstab — the GPL-licensed encoders in the previous bundled build — are not compiled in. There is no GPL Corresponding Source obligation for this binary.

**Relationship to the app's own license.** WaxOn/WaxOff is licensed GPL-3.0 (top-level `LICENSE`). The app invokes `ffmpeg`/`ffprobe` as **separate executables** (via `Process()`), so they are aggregated with the app rather than linked into it — under GPL's mere-aggregation provision the app's license and the binaries' licenses apply independently, and there is no combined-work question between them.

### One live source obligation, satisfied

This is not "no obligation". The ffmpeg binary statically links LGPL components — FFmpeg's own core (LGPL-2.1-or-later) and **LAME** (LGPL-2.0-or-later) — and LGPL §6 requires their source be available when they are distributed statically linked.

It is satisfied by construction:

- **The recipe** is `scripts/build-ffmpeg.sh`, committed here, pinning both versions with SHA-256 checksums and recording the exact configure line.
- **FFmpeg 8.0 source**: https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz (verify with the PGP signature above).
- **LAME 3.100 source**: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz

Because the binaries are conveyed by network download (bundled in the app DMG, and as raw assets on the deps release), the applicable clause is GPL-3.0 §6(d) / the equivalent LGPL provision: source is offered from the same place, or from the upstream projects with directions accompanying the object code. Those directions appear in the release descriptions as well as here. You can also open a GitHub issue with subject **source request**.

### Updating the bundled binary build

1. Adjust pins in `scripts/build-ffmpeg.sh` if the FFmpeg or LAME version changes.
2. Run `scripts/build-ffmpeg.sh`; it verifies flags, deployment target, dynamic dependencies and prints SHA-256s.
3. Update `Vendor/ffmpeg-manifest.env` (version, tag, SHA-256 sums).
4. Publish a new GitHub release with the tag from the manifest; upload assets named `ffmpeg` and `ffprobe`, and include the source directions in the release description.
5. Re-run the parity harness (`scripts/parity-corpus-gen.sh`, `scripts/parity-check.sh`) against the previous binary before shipping.

---

## RNNoise (measurement-only denoising)

WaxOn runs RNNoise during the loudnorm pass-1 analysis only — never on the exported audio — via FFmpeg's built-in `arnndn` filter, which reads a bundled weights file. Two distinct third-party components are involved; they have different licenses and sources.

### `arnndn` filter code

The RNNoise algorithm is implemented directly in FFmpeg (`libavfilter/af_arnndn.c`) and compiled into the bundled `ffmpeg` binary. The app does **not** ship or link Xiph's `librnnoise`.

| Field | Value |
|-------|--------|
| Source | FFmpeg `libavfilter/af_arnndn.c` (compiled into the bundled `ffmpeg`) |
| License | **BSD-2-Clause** (verified at `libavfilter/af_arnndn.c:10-19` of the pinned source — two conditions, no advertising clause) |
| Copyright | Gregor Richards (2018); Mozilla (2017); Xiph.Org Foundation (2005–2009); CSIRO (2007–2008); Octasic Inc. (2008–2011); Jean-Marc Valin; Paul B Mahol (2019) — all seven notices at `af_arnndn.c:2-8` |
| Algorithm lineage | RNNoise — https://github.com/xiph/rnnoise (Jean-Marc Valin) |

Because this code is compiled inside the FFmpeg binary, its source is covered by the FFmpeg source pointers above. The BSD-2-Clause attribution requirement is independent of that and is satisfied by naming the copyright holders here.

### Model weights file (`WaxOnWaxOff/rnnoise`)

A separate binary weights file (no extension) supplies the trained model to `arnndn`.

| Field | Value |
|-------|--------|
| Source | https://github.com/GregorR/rnnoise-models |
| Format | rnnoise-nu (`rnnoise-nu model file version 1`) — mono 48 kHz speech model |
| Status | Upstream states the model files "are not creative and thus none of it is subject to copyright." Reproduced here as the upstream project's position, not as a legal determination by this project. |

The app bundles a binary copy of the weights file, not the training codebase.

---

## Historical builds

App releases up to and including **v2.3.0** bundled a third-party static FFmpeg 8.0 built **with** `--enable-gpl`, linking x264, x265 and libvidstab. Those artifacts remain published, and the GPL Corresponding Source directions for them are on the `ffmpeg-deps-8.0-arm64` and `v2.3.0` release pages. They are superseded, not withdrawn.

---

## Refresh after clone

Requires **Xcode 26 or later (Swift 6.2+)** — see the build floor in the top-level `README.md`.

```bash
./scripts/fetch-ffmpeg.sh
open WaxOnWaxOff.xcodeproj
```
