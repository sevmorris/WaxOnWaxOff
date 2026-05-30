# Vendor dependencies

## FFmpeg / ffprobe

WaxOnWaxOff bundles static FFmpeg 8.0 binaries for macOS **arm64 (Apple Silicon only)**. They are **not** stored in git (~100 MB combined). Instead:

- Checksums and the release tag live in `ffmpeg-manifest.env`
- `scripts/fetch-ffmpeg.sh` downloads verified binaries from the pinned GitHub release
- Xcode runs that script before each build; `release.sh` runs it before packaging

To refresh after a clone:

```bash
./scripts/fetch-ffmpeg.sh
```

### Updating the bundled build

1. Replace `WaxOnWaxOff/ffmpeg` and `WaxOnWaxOff/ffprobe` locally.
2. Update `ffmpeg-manifest.env` (version, tag, SHA-256 sums).
3. Publish a new GitHub release with the tag from the manifest and upload both binaries as release assets named `ffmpeg` and `ffprobe`.

### GPL source offer

FFmpeg is licensed under LGPL/GPL depending on build flags. Corresponding source code is available from [ffmpeg.org](https://ffmpeg.org/download.html). Request a copy of the exact source matching the bundled build via the project’s GitHub issues.
