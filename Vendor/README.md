# Vendor dependencies

## FFmpeg / ffprobe (bundled binaries)

WaxOnWaxOff bundles **static FFmpeg 8.0** binaries for macOS **arm64 (Apple Silicon only)**. They are **not** stored in git (~100 MB combined). Instead:

| Artifact | Location |
|----------|----------|
| Binary checksums & release tag | `Vendor/ffmpeg-manifest.env` |
| Download script | `scripts/fetch-ffmpeg.sh` |
| GitHub release assets | Tag from manifest (e.g. `ffmpeg-deps-8.0-arm64`) |

Xcode runs `scripts/fetch-ffmpeg.sh` before each build; `release.sh` runs it before packaging.

**Do not delete** the `ffmpeg-deps-*` GitHub release — CI and fresh clones fetch binaries from it. `release.sh` only prunes old `v*` app releases.

### Pinned binary build (manifest)

See `ffmpeg-manifest.env` for:

- `FFMPEG_VERSION`, `FFMPEG_ARCH`, `FFMPEG_DEPS_TAG`
- SHA-256 of `ffmpeg` and `ffprobe` after download

Verify locally:

```bash
./scripts/fetch-ffmpeg.sh   # skips network when checksums match
shasum -a 256 WaxOnWaxOff/ffmpeg WaxOnWaxOff/ffprobe
```

### Corresponding **source code** (GPL offer)

The bundled executables report:

```text
ffmpeg version 8.0
configuration: … --enable-gpl --arch=arm64 … (static build)
```

| Field | Value |
|-------|--------|
| Upstream release | **FFmpeg 8.0** (“Huffman”), released 2025-08-22 |
| Source archive | https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz |
| PGP signature | https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz.asc |
| Git tag (reference) | `n8.0` — https://git.ffmpeg.org/gitweb/ffmpeg.git/log/refs/heads/release/8.0 |
| License | **GPL-2.0-or-later** (this static build was configured with `--enable-gpl` and no `--enable-version3`; the effective license is GPL-2.0-or-later, not GPLv3) |

FFmpeg does not publish a separate SHA-256 file for release tarballs; verify the archive with the **PGP signature** and the project’s release signing key (see https://ffmpeg.org/download.html#releases).

To obtain source matching this major version:

```bash
curl -LO https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz
curl -LO https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz.asc
gpg --verify ffmpeg-8.0.tar.xz.asc ffmpeg-8.0.tar.xz
```

For a written offer or archived copy of the exact sources used to produce the bundled binaries, open a GitHub issue on [sevmorris/WaxOnWaxOff](https://github.com/sevmorris/WaxOnWaxOff/issues) with subject **GPL source request**.

### Updating the bundled **binary** build

1. Replace `WaxOnWaxOff/ffmpeg` and `WaxOnWaxOff/ffprobe` locally (arm64, static, GPL flags documented).
2. Update `ffmpeg-manifest.env` (version, tag, SHA-256 sums).
3. Publish a new GitHub release with the tag from the manifest; upload assets named `ffmpeg` and `ffprobe`.
4. Update the **source** table in this file if the upstream release version changes.

---

## RNNoise (measurement-only denoising)

WaxOn runs RNNoise during the loudnorm pass-1 analysis only — never on the exported audio — via FFmpeg's built-in `arnndn` filter, which reads a bundled weights file. Two distinct third-party components are involved; they have different licenses and sources.

### `arnndn` filter code

The RNNoise algorithm is implemented directly in FFmpeg (`libavfilter/af_arnndn.c`) and compiled into the bundled `ffmpeg` binary. The app does **not** ship or link Xiph's `librnnoise`.

| Field | Value |
|-------|--------|
| Source | FFmpeg `libavfilter/af_arnndn.c` (compiled into the bundled `ffmpeg`) |
| License | **BSD-2-Clause** |
| Copyright | Mozilla; Xiph.Org Foundation; Jean-Marc Valin; Gregor Richards; Paul B Mahol (see the file header for the full notice) |
| Algorithm lineage | RNNoise — https://github.com/xiph/rnnoise (Jean-Marc Valin) |

Because this code is compiled inside the FFmpeg binary, its corresponding source is covered by the FFmpeg GPL source offer above. The BSD-2-Clause attribution requirement is independent of that offer and is satisfied by naming the copyright holders here.

### Model weights file (`WaxOnWaxOff/rnnoise`)

A separate binary weights file (no extension) supplies the trained model to `arnndn`.

| Field | Value |
|-------|--------|
| Source | https://github.com/GregorR/rnnoise-models |
| Format | rnnoise-nu (`rnnoise-nu model file version 1`) — mono 48 kHz speech model |
| Status | Upstream states the model files "are not creative and thus none of it is subject to copyright." Reproduced here as the upstream project's position, not as a legal determination by this project. |

The app bundles a binary copy of the weights file, not the training codebase.

---

## Refresh after clone

```bash
./scripts/fetch-ffmpeg.sh
open WaxOnWaxOff.xcodeproj
```
