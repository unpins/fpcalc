{
  description = "Standalone build of fpcalc (Chromaprint audio fingerprinter)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Chromaprint ships a single user CLI, `fpcalc` (the library libchromaprint
  # is not user-facing). fpcalc only *decodes* audio: it demuxes/decodes a file
  # to PCM via FFmpeg, then fingerprints it. So the only mandatory dependency is
  # FFmpeg — but the full ffmpeg-headless drags a video-codec/subtitle/network
  # closure (x264/x265/aom/dav1d/gnutls/…) that fpcalc never touches, and some of
  # it (libopenmpt→mpg123→pulse, v4l2→libbpf→elfutils, vaapi→libva) is
  # badPlatforms under pkgsStatic.
  #
  # `minimalFfmpeg` cuts FFmpeg to a decode-only core: just the four libraries
  # chromaprint's CMake looks for (avcodec/avformat/avutil + swresample, the
  # last two also providing the av_tx FFT fpcalc uses), with every external
  # codec library off. FFmpeg's *native* decoders still cover mp3/flac/vorbis/
  # aac/opus/wav, so format coverage is unchanged. fpcalc links only those four
  # .a's — avfilter/swscale aren't built. doCheck is forced off because FFmpeg's
  # checkPhase runs `make check`, which builds alltools+testprogs (uncoded_frame
  # wants avdevice+avfilter, and a libavutil pixelutils test mis-compiles under a
  # trimmed config) — none of which we ship.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      minimalFfmpeg = ffmpeg:
        let
          host = ffmpeg.stdenv.hostPlatform;
          isRiscV = host.isRiscV or false;
          isWindows = host.isWindows or false;
          isDarwin = host.isDarwin or false;
        in
        (ffmpeg.override {
          withHeadlessDeps = false;
          withSmallDeps = false;
          withFullDeps = false;
          buildAvcodec = true;
          buildAvformat = true;
          buildAvutil = true;
          buildSwresample = true;
        }).overrideAttrs (old: {
          doCheck = false;
          # nixpkgs blanket-marks ffmpeg broken on mingw64 (the full codec build
          # doesn't cross cleanly). Our decode-only core (no external codec libs)
          # is a far simpler build and does cross — clear the mark for it.
          meta = old.meta // { broken = false; };
          # On mingw, libavcodec still bundles Windows-only video paths whose COM
          # GUIDs (IID_ICodecAPI for the MediaFoundation encoder, IID_ID3D11… for
          # the D3D/DXVA hwaccels) resolve via ffmpeg's own -lmfuuid/-lstrmiids/…
          # extralibs. chromaprint links the .a directly (not via ffmpeg's
          # pkg-config), so those libs are absent and the GUIDs go undefined.
          # fpcalc decodes audio and uses none of this — disable it. macOS has
          # the same shape: libavcodec's AudioToolbox/VideoToolbox codecs
          # reference Apple framework symbols (_AudioConverter*, _CF*) that
          # ffmpeg resolves with its own -framework flags; linking the .a direct
          # leaves them undefined. fpcalc uses FFmpeg's native decoders (native
          # AAC, not AudioToolbox), so drop both.
          configureFlags = (old.configureFlags or [ ])
            ++ (if isWindows then [
              "--disable-mediafoundation"
              "--disable-d3d11va"
              "--disable-d3d12va"
              "--disable-dxva2"
            ] else [ ])
            ++ (if isDarwin then [
              "--disable-audiotoolbox"
              "--disable-videotoolbox"
            ] else [ ]);
          # libavutil/riscv/cpu.c builds whenever <asm/hwprobe.h> is present and
          # calls syscall(__NR_riscv_hwprobe, …), but this musl's <sys/syscall.h>
          # predates that syscall, so the constant is undeclared. It's a stable
          # kernel ABI number (258); define it (riscv64 only) so the runtime
          # probe compiles — the kernel returns ENOSYS on older hosts and ffmpeg
          # falls back to getauxval. Route through `env` (ffmpeg sets
          # NIX_CFLAGS_COMPILE there under strict structured-attrs).
          env = old.env // {
            NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "")
              + (if isRiscV then " -D__NR_riscv_hwprobe=258" else "");
          };
        });

      # `sp` is the static package set for the target (pkgsStatic or
      # mingwStaticCross); we take chromaprint/ffmpeg-headless/libcxx from it.
      # withExamples drops the demo binaries; withTools (default) keeps fpcalc.
      mk = sp:
        let
          chromaprint = sp.chromaprint;
          host = chromaprint.stdenv.hostPlatform;
          isWindows = host.isWindows or false;
          isDarwin = host.isDarwin or false;
        in
        (chromaprint.override {
          ffmpeg-headless = minimalFfmpeg sp.ffmpeg-headless;
          withExamples = false;
        }).overrideAttrs (old: {
          doCheck = false;
          # chromaprint is C++. On mingw its CMake links fpcalc.exe without
          # -static, so the toolchain runtime (libstdc++-6.dll, libgcc_s_seh-1.dll)
          # rides along as companion DLLs — `-static` folds it in, leaving only
          # system DLLs (kernel32/msvcrt/shell32/bcrypt). On darwin the link
          # would pull the dynamic /usr/lib/libc++.1.dylib, which the unpins
          # portability allowlist rejects; -search_paths_first makes ld64 prefer
          # the static libc++ from the shim that preConfigure plants below.
          cmakeFlags = (old.cmakeFlags or [ ])
            ++ (if isWindows then [ "-DCMAKE_EXE_LINKER_FLAGS=-static" ] else [ ])
            ++ (if isDarwin then [ "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-search_paths_first" ] else [ ]);
          preConfigure = (old.preConfigure or "") + (if isDarwin then ''
            # Expose static libc++/libc++abi as libc++.a/libstdc++.a/libc++abi.a
            # ahead of the dylib dirs; combined with -search_paths_first this
            # folds libc++ into fpcalc instead of importing the dylib.
            mkdir -p "$TMPDIR/cxx-static"
            ln -sf ${sp.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libc++.a"
            ln -sf ${sp.libcxx}/lib/libc++.a    "$TMPDIR/cxx-static/libstdc++.a"
            ln -sf ${sp.libcxx}/lib/libc++abi.a "$TMPDIR/cxx-static/libc++abi.a"
            export NIX_LDFLAGS="-L$TMPDIR/cxx-static $NIX_LDFLAGS"
          '' else "");
        });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "fpcalc";
      # Package name (fpcalc) differs from the nixpkgs attr (chromaprint), but
      # there's no man graft to mis-resolve here (embedMan = false), so no
      # pkgsAttr is needed.
      embedMan = false;
      smoke = [ "-version" ];
      smokePattern = "fpcalc version 1\\.6";
      build = pkgs: mk pkgs.pkgsStatic;
      windowsBuild = pkgs: mk (ulib.mingwStaticCross pkgs);
    };
}
