# Changelog

## [Unreleased]

### Changed

- fpcalc now carries the same FFmpeg as the `ffmpeg` package instead of a
  decode-only cut of it. It reads http and https URLs, tracker modules
  (MOD/XM/IT/S3M) and the formats behind FFmpeg's external libraries; the
  fingerprints of formats it already read are unchanged. The Linux x86_64
  binary grows from 19 MB to 97 MB.

## [1.6.0-2] - 2026-09-26

### Changed

- The Windows binary is now built by the same compiler as the Linux and macOS
  ones. It is about 15% smaller (22.0 MB to 18.8 MB); `-version` and the
  fingerprint of upstream's reference recording were checked under Wine.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.
