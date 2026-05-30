# Vendor dependencies

## FFmpeg / ffprobe (bundled binaries)

WaxOnWaxOff bundles **static FFmpeg 8.0** binaries for macOS **arm64 (Apple Silicon only)**. They are **not** stored in git (~100 MB combined). Instead:

| Artifact | Location |
|----------|----------|
| Binary checksums & release tag | `Vendor/ffmpeg-manifest.env` |
| Download script | `scripts/fetch-ffmpeg.sh` |
| GitHub release assets | Tag from manifest (e.g. `ffmpeg-deps-8.0-arm64`) |

Xcode runs `scripts/fetch-ffmpeg.sh` before each build; `release.sh` runs it before packaging.

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
| License | **GPLv3** (this static build was configured with `--enable-gpl`) |

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

## RNNoise model (`WaxOnWaxOff/rnnoise`)

WaxOn uses the bundled RNNoise weights file (no extension) for **measurement-only** denoising during loudnorm pass 1.

| Field | Value |
|-------|--------|
| Project | https://github.com/xiph/rnnoise |
| License | BSD 3-Clause |
| Format | Mono 48 kHz speech model (used via FFmpeg `arnndn`) |

Source for the model weights is maintained in the upstream RNNoise repository. The app bundles a binary copy of the model file, not the full training codebase.

---

## Refresh after clone

```bash
./scripts/fetch-ffmpeg.sh
open WaxOnWaxOff.xcodeproj
```
