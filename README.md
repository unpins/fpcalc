# fpcalc

[fpcalc](https://github.com/acoustid/chromaprint) — the Chromaprint audio
fingerprinting CLI (used by AcoustID/MusicBrainz). A single self-contained
binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/fpcalc/actions/workflows/fpcalc.yml/badge.svg)](https://github.com/unpins/fpcalc/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Reads an audio file in any common format (MP3/FLAC/Ogg/AAC/Opus/WAV/…) or from
an http(s) URL, decodes it, and prints its Chromaprint fingerprint — with a
full FFmpeg built in.

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install fpcalc`.

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
- FFmpeg is the same build the [`ffmpeg`](https://github.com/unpins/ffmpeg)
  package ships, so `fpcalc` reads every format and protocol it does: network
  URLs, tracker modules (MOD/XM/IT/S3M), and the codecs behind external
  libraries.
- **https:** server certificates are not checked, as in upstream FFmpeg, and
  `fpcalc` has no option to turn the check on.
- **Windows:** needs the Universal C Runtime, which is part of Windows 10 and
  later and comes through Windows Update on 7 and 8.1.
- **Not included:** what the `ffmpeg` package leaves out (hardware decoding
  among it), and a man page — upstream ships none.
- **Tests:** upstream's suite runs on every build that can execute what it just
  produced (Linux x86_64, i686 and arm64, macOS). Beyond its unit tests it
  fingerprints a nine-megabyte recording and checks the result against a known
  hash. The installed binary is then checked against the answer key upstream
  keeps beside its code: a sample MP3 and the exact output `fpcalc` must print
  for it. Windows, ppc64le, riscv64 and armv7l can't run where they are built,
  so CI stops at the version smoke there; their fingerprints of that MP3 were
  compared by hand and match the answer key.
