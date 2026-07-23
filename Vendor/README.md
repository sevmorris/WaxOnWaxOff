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
configuration: --prefix=/Volumes/tempdisk/sw --extra-cflags=-fno-stack-check --arch=arm64 --cc=/usr/bin/clang --enable-gpl --enable-libvmaf --enable-libopenjpeg --enable-libopus --enable-libmp3lame --enable-libx264 --enable-libx265 --enable-libvvenc --enable-libvpx --enable-libwebp --enable-libass --enable-libfreetype --enable-fontconfig --enable-libtheora --enable-libvorbis --enable-libsnappy --enable-libaom --enable-libvidstab --enable-libzimg --enable-libsvtav1 --enable-libharfbuzz --enable-libkvazaar --pkg-config-flags=--static --enable-ffplay --enable-neon --enable-runtime-cpudetect --disable-indev=qtkit --disable-indev=x11grab_xcb
```

The full configuration line above is the exact one the bundled binary reports (`ffmpeg -version`). `--enable-gpl` together with the GPL-licensed encoders in this build (`libx264`, `libx265`, `libvidstab`) is what makes the combined work GPL — see the license note below.

| Field | Value |
|-------|--------|
| Upstream release | **FFmpeg 8.0** (“Huffman”), released 2025-08-22 |
| Source archive | https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz |
| PGP signature | https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz.asc |
| Git tag (reference) | `n8.0` — https://git.ffmpeg.org/gitweb/ffmpeg.git/log/refs/heads/release/8.0 |
| License | **GPL-2.0-or-later** (this static build was configured with `--enable-gpl` and no `--enable-version3`; the effective license is GPL-2.0-or-later, not GPLv3) |

**Compatibility with the app's own license.** WaxOn/WaxOff is licensed GPL-3.0 (top-level `LICENSE`). Bundling this **GPL-2.0-or-later** FFmpeg build into a GPL-3.0 application is compatible *because of the "or later"*: the terms permit distributing the combined work under GPL-3.0. A GPL-2.0-**only** FFmpeg build would have been incompatible with a GPL-3.0 app.

FFmpeg does not publish a separate SHA-256 file for release tarballs; verify the archive with the **PGP signature** and the project’s release signing key (see https://ffmpeg.org/download.html#releases).

To obtain source matching this major version:

```bash
curl -LO https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz
curl -LO https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz.asc
gpg --verify ffmpeg-8.0.tar.xz.asc ffmpeg-8.0.tar.xz
```

**Which GPL mechanism applies.** The FFmpeg binary is conveyed only by network download — bundled in the app DMG and hosted as raw assets on the `ffmpeg-deps-8.0-arm64` release, both offered from GitHub Releases. That is GPL-3.0 **§6(d)** ("offering access from a designated place"), not the §6(b) written-offer route, which is scoped to object code conveyed in or with a physical product. §6(d) permits the Corresponding Source to live on a third-party server with equivalent copying facilities, provided clear directions to it accompany the object code.

For FFmpeg's own source, the pointer is upstream **FFmpeg 8.0** at [ffmpeg.org/releases/ffmpeg-8.0.tar.xz](https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz) (verify with the PGP signature above), built with the exact configuration shown above.

> **⚠ This source offer is known-incomplete.** Because this is a statically linked GPL build, the *complete* Corresponding Source must also include per-component source for the statically linked GPL libraries — **x264, x265, and libvidstab** (each GPL-2.0-or-later) — which is **not yet provided**. Their exact linked versions are not recoverable from the binary, and the origin build's source manifest is not available. This is being resolved (see [#7](https://github.com/sevmorris/WaxOnWaxOff/issues/7)); one likely resolution rebuilds FFmpeg audio-only with no GPL components, which removes the obligation entirely.

A second, separate gap: §6(d) requires the source directions *next to the object code* on the download pages themselves; today they live here in `Vendor/README.md` rather than in the release descriptions. Closing that is a release-process task tracked in [#5](https://github.com/sevmorris/WaxOnWaxOff/issues/5). For a copy of the corresponding source you can also open a GitHub issue with subject **GPL source request**.

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
| Copyright | Mozilla; Xiph.Org Foundation; CSIRO; Octasic Inc.; Jean-Marc Valin; Gregor Richards; Paul B Mahol (all seven notices verbatim in the file header) |
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
