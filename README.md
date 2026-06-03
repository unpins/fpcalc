# fpcalc

Standalone build of [fpcalc](https://github.com/acoustid/chromaprint) — the
Chromaprint audio fingerprinting CLI (used by AcoustID/MusicBrainz).

[![CI](https://github.com/unpins/fpcalc/actions/workflows/fpcalc.yml/badge.svg)](https://github.com/unpins/fpcalc/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Reads an audio file in any common format (MP3/FLAC/Ogg/AAC/Opus/WAV/…), decodes
it, and prints its Chromaprint fingerprint — with a full FFmpeg decoder linked in
statically.

## Usage

Run the `fpcalc` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin fpcalc song.mp3
```

To install it onto your PATH:

```bash
unpin install fpcalc
```

## Build locally

```bash
nix build github:unpins/fpcalc
./result/bin/fpcalc -version
```

Or run directly:

```bash
nix run github:unpins/fpcalc -- song.flac
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/fpcalc/releases) page has standalone binaries for manual download.

## Build notes

- Single upstream CLI (`fpcalc`); the `libchromaprint` library is not
  user-facing, so it is linked in rather than shipped.
- fpcalc only **decodes** audio, so FFmpeg is cut to a decode-only core — just
  `libavcodec`/`libavformat`/`libavutil`/`libswresample`, with **no external
  codec libraries**. FFmpeg's native decoders still cover the common formats, so
  the full video/subtitle/network closure (x264/x265/dav1d/gnutls/…) is dropped.
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs (the C++ runtime
  is folded static). FFmpeg's Windows-only MediaFoundation/D3D/DXVA paths are
  disabled — fpcalc never uses them and their COM GUIDs would otherwise go
  undefined when linking the library directly.
- No man page upstream, so none is embedded.
