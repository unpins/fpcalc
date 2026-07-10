{
  description = "fpcalc (Chromaprint audio fingerprinter) as a single self-contained binary";

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

      # chromaprint is C++; build it under the unpin-llvm engine (all objects
      # bitcode, cmake drives the whole-program LTO link through the engine
      # cc-wrapper). FFmpeg's decode-only .a's link as ordinary static archives.
      engStdenv = pkgs:
        let sp = pkgs.pkgsStatic; in
        ulib.unpinAdapterStdenv {
          inherit pkgs;
          target = sp.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = true;
          lto = true;
        };

      # Non-LTO engine stdenv, used for FFmpeg on darwin only. clang-21's
      # whole-program LTO miscompiles FFmpeg's teardown code on x86_64-darwin
      # (a 64-bit pointer is emitted as a 32-bit `movl`, truncating it → SIGSEGV
      # on the first decode) — the same class of LTO/-O2 codegen bug the Zig
      # project hit upstream (llvm/llvm-project#186922, ziglang/zig#20198). We
      # verified per-TU engine codegen is fine and only the LTO link step is
      # wrong: building FFmpeg with the engine clang but WITHOUT -flto decodes
      # correctly (identical fingerprint), while -flto SIGSEGVs. FFmpeg's
      # decode-only .a's link into chromaprint as ordinary static archives
      # regardless, so dropping LTO for them costs nothing and keeps the shipped
      # binary a single static object. Linux/windows are unaffected (they decode
      # fine under LTO — this is darwin-specific codegen) and keep it.
      ffStdenv = pkgs:
        let sp = pkgs.pkgsStatic; in
        ulib.unpinAdapterStdenv {
          inherit pkgs;
          target = sp.stdenv.hostPlatform.config;
          native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
          cxx = false;
          lto = false;
        };

      # `appleSdk` (darwin only) overrides ffmpeg's `apple-sdk_15` callPackage param
      # down to the default apple-sdk (14.4). ffmpeg is the only catalog package
      # pinning SDK 15; under pkgsStatic that rebuilds Apple's Csu (crt) from the
      # 15.5 source, whose Makefile links crt1.o with `ld -r` — which ld64.lld does
      # not implement, so the engine's crt-less Mach-O link fails on undefined
      # `main`. The 14.4 Csu (what every other engine-darwin package uses, e.g.
      # curl) builds cleanly. fpcalc disables audiotoolbox/videotoolbox, so no
      # SDK-15 framework is needed; headers/frameworks come via the engine SDKROOT.
      minimalFfmpeg = { ffmpeg, appleSdk ? null, ffmpegStdenv ? null }:
        let
          host = ffmpeg.stdenv.hostPlatform;
          isRiscV = host.isRiscV or false;
          isWindows = host.isWindows or false;
          isDarwin = host.isDarwin or false;
          isAarch32 = host.isAarch32 or false;
          isPower = host.isPower or false;
        in
        (ffmpeg.override ({
          withHeadlessDeps = false;
          withSmallDeps = false;
          withFullDeps = false;
          buildAvcodec = true;
          buildAvformat = true;
          buildAvutil = true;
          buildSwresample = true;
        } // (if isDarwin && appleSdk != null then { apple-sdk_15 = appleSdk; } else { })
          // (if ffmpegStdenv != null then { stdenv = ffmpegStdenv; } else { }))).overrideAttrs (old: {
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
            # Native builds run under the unpin-llvm engine, whose cc-wrapper
            # exposes `<triple>-cc`/`-clang`/`-c++` but NO `<triple>-gcc`.
            # ffmpeg's configure defaults its cross compiler to
            # `${cross-prefix}gcc`, which isn't found. Point it at the engine's
            # `cc`/`c++` explicitly. Windows (mingw, off-engine) keeps the real
            # `${prefix}gcc`, so gate this off there.
            ++ (if !isWindows then [
              "--cc=${host.config}-cc"
              "--cxx=${host.config}-c++"
            ] else [ ])
            ++ (if isWindows then [
              "--disable-mediafoundation"
              "--disable-d3d11va"
              "--disable-d3d12va"
              "--disable-dxva2"
            ] else [ ])
            ++ (if isDarwin then [
              "--disable-audiotoolbox"
              "--disable-videotoolbox"
            ] else [ ])
            # Enable each arch's guaranteed SIMD baseline so FFmpeg's inline asm
            # carries the right subtarget features into the whole-program LTO
            # codegen (otherwise ld.lld re-assembles it without them and rejects
            # NEON/VSX). x86 SIMD is external NASM and unaffected.
            ++ (if isAarch32 then [ "--extra-cflags=-mfpu=neon" ]
                else if isPower then [ "--cpu=power8" "--extra-cflags=-mvsx" ]
                else [ ]);
          # ppc64le: configure's `check_inline_asm ppc4xx '"maclhw…"'` probe
          # false-positives under the engine (clang's native asm parser accepts
          # the PPC405/440 `maclhw`/`mullhw` even for a POWER8 target), so it sets
          # HAVE_PPC4XX=1 and libavcodec/ppc/mathops.h emits those embedded-only
          # MACs — which ld.lld's stricter LTO codegen then rejects as invalid.
          # `--disable-ppc4xx` only clears CONFIG_PPC4XX, not the HAVE_ capability
          # the header guards on, so neutralize the guard at the source (the only
          # maclhw/mullhw users in the tree; MULH's `mulhw` is standard POWER and
          # MAC64/MLS64 are `#if !ARCH_PPC64`, both fine). POWER8 is not a 4xx core,
          # so this is a misdetection fix, not a feature loss.
          postPatch = (old.postPatch or "")
            + (if isPower then ''
              substituteInPlace libavcodec/ppc/mathops.h \
                --replace-fail '#if HAVE_PPC4XX' '#if 0'
            '' else "");
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
      mk = { sp, engineStdenv ? null, appleSdk ? null, ffmpegStdenv ? null }:
        let
          chromaprint = sp.chromaprint;
          host = chromaprint.stdenv.hostPlatform;
          isWindows = host.isWindows or false;
          hostIsDarwin = host.isDarwin or false;
          # Under the engine (native builds) the adapter folds static libc++ for
          # us, so the darwin cmake/link shim below is only needed on the
          # non-engine path (there is none today, but keep it gated cleanly).
          isDarwin = hostIsDarwin && engineStdenv == null;
        in
        (chromaprint.override ({
          ffmpeg-headless = minimalFfmpeg {
            ffmpeg = sp.ffmpeg-headless;
            inherit appleSdk ffmpegStdenv;
          };
          withExamples = false;
        } // sp.lib.optionalAttrs (engineStdenv != null) { stdenv = engineStdenv; })).overrideAttrs (old: {
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
            ++ (if isDarwin then [ "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-search_paths_first" ] else [ ])
            # darwin (engine included): pin the FFT to FFmpeg's av_tx (the same
            # backend linux/windows use) instead of letting cmake auto-pick
            # Apple's vDSP when it finds Accelerate via SDKROOT. av_tx keeps the
            # binary framework-free (only libSystem), uniform across platforms;
            # its teardown is fine now the LTO miscompile is gone (see ffStdenv).
            ++ (if hostIsDarwin then [ "-DFFT_LIB=avtx" ] else [ ]);
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
      # fpcalc has no upstream man page (chromaprint ships none), so embedMan is
      # left default-on only to run the post-build embed wrap — the man step
      # warn-skips (nothing to graft), but the wrap is also what applies
      # removeReferences below. binName drives the (absent) man lookup, not the
      # chromaprint attr, so no pkgsAttr is needed.
      binName = "fpcalc";
      smoke = [ "-version" ];
      smokePattern = "fpcalc version 1\\.6";
      engine = "unpin-llvm";
      # libavutil bakes ffmpeg's configure line (including `--prefix=/nix/store/
      # …-ffmpeg-headless-…`) into its build-config string, which chromaprint
      # links in. Those paths are inert (fpcalc never reads them), but nix scans
      # them as references. Scrub them so the shipped binary stays 0-ref.
      removeReferences = [ "ffmpeg-headless" ];
      build = pkgs: mk {
        sp = pkgs.pkgsStatic;
        engineStdenv = engStdenv pkgs;
        # Give ffmpeg the DYNAMIC apple-sdk (from `pkgs`, not pkgsStatic). Its
        # pkgsStatic variant is the static SDK that rebuilds Apple's Csu/crt — see
        # minimalFfmpeg. The dynamic SDK provides ffmpeg's framework/header
        # references without that rebuild; the engine links against the real SDK
        # via SDKROOT regardless.
        appleSdk = if pkgs.stdenv.hostPlatform.isDarwin then pkgs.apple-sdk else null;
        # darwin only: build ffmpeg with the engine clang but no -flto, dodging
        # the clang-21 LTO codegen miscompile of ffmpeg's teardown (see ffStdenv).
        ffmpegStdenv = if pkgs.stdenv.hostPlatform.isDarwin then ffStdenv pkgs else null;
      };
      windowsBuild = pkgs: mk { sp = ulib.mingwStaticCross pkgs; };
    };
}
