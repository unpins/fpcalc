# Changelog

## [Unreleased]

## [1.6.0-2] - 2026-09-26

### Changed

- The Windows binary is now built by the same compiler as the Linux and macOS
  ones. It is about 15% smaller (22.0 MB to 18.8 MB); `-version` and the
  fingerprint of upstream's reference recording were checked under Wine.

  It now uses the Universal C Runtime, which is part of Windows 10 and later.
  On Windows 7 or 8.1 that runtime has to be installed first — it comes through
  Windows Update. The previous binary did not need it.
