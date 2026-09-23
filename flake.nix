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
          # The multicall module hook replays fpcalc's link from its sidecar.
          captureLinks = true;
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
            # Every target builds under the unpin-llvm engine, whose cc-wrapper
            # exposes `<triple>-cc`/`-clang`/`-c++` but NO `<triple>-gcc`.
            # ffmpeg's configure defaults its cross compiler to
            # `${cross-prefix}gcc`, which isn't found. Point it at the engine's
            # `cc`/`c++` explicitly.
            ++ [
              "--cc=${host.config}-cc"
              "--cxx=${host.config}-c++"
            ]
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
            '' else "")
            # mingw: configure's guard for llvm/llvm-project#76046 (LTO + COFF
            # cannot see labels defined inside inline asm) sits under ffmpeg's
            # own `--enable-lto`, while here `-flto` comes from the engine
            # stdenv. The probe then passes, and mlpdsp's `ff_mlp_*order_*`
            # come out undefined at fpcalc's link. Same fix as the ffmpeg
            # package.
            + (if isWindows then ''
              substituteInPlace configure \
                --replace-fail 'check_inline_asm inline_asm_nonlocal_labels' \
                               'disable inline_asm_nonlocal_labels #'
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
      # mingwStaticCross); we take chromaprint/ffmpeg-headless from it.
      # withExamples drops the demo binaries; withTools (default) keeps fpcalc.
      mk = { sp, engineStdenv ? null, appleSdk ? null, ffmpegStdenv ? null }:
        let
          chromaprint = sp.chromaprint;
          host = chromaprint.stdenv.hostPlatform;
          hostIsDarwin = host.isDarwin or false;
          # "can this host run what it just built" — true on the three native
          # CI jobs, false on every cross target.
          canRun = chromaprint.stdenv.buildPlatform.canExecute host;
        in
        (chromaprint.override ({
          ffmpeg-headless = minimalFfmpeg {
            ffmpeg = sp.ffmpeg-headless;
            inherit appleSdk ffmpegStdenv;
          };
          withExamples = false;
        } // sp.lib.optionalAttrs (engineStdenv != null) { stdenv = engineStdenv; })).overrideAttrs (old: {
          # Upstream's suite is 98 unit tests plus a fingerprint of a real
          # 9 MB recording compared against a known hash. It passes under
          # static musl and the engine and runs in milliseconds.
          doCheck = canRun;
          # Then the same question of the binary that actually ships, after the
          # strip: upstream keeps an answer key beside the code — a sample MP3
          # and the exact output fpcalc must print for it, which upstream's own
          # CI diffs on Linux, macOS and Windows. The smoke gate (`-version`)
          # decodes nothing: the one bug this package has hit, a clang LTO
          # miscompile of FFmpeg's teardown on darwin, crashed on the first
          # decode and stayed green through all of it.
          doInstallCheck = canRun;
          installCheckPhase = ''
            runHook preInstallCheck
            "$out/bin/fpcalc" -raw "$src/tests/data/test.mp3" \
              | diff -u - "$src/tests/data/test.mp3.fpcalc.out"
            runHook postInstallCheck
          '';
          # chromaprint is C++, and every target here builds under the engine,
          # whose clang++ links its own static libc++/libc++abi by default. No
          # archive is named and nothing imports /usr/lib/libc++.1.dylib, so the
          # darwin allowlist (otool -L = libSystem only) is satisfied without
          # naming nixpkgs' libc++ — see docs/platforms/darwin.md.
          #
          # darwin: pin the FFT to FFmpeg's av_tx (the same backend linux/windows
          # use) instead of letting cmake auto-pick Apple's vDSP when it finds
          # Accelerate via SDKROOT. av_tx keeps the binary framework-free, uniform
          # across platforms; its teardown is fine now the LTO miscompile is gone
          # (see ffStdenv).
          cmakeFlags = (old.cmakeFlags or [ ])
            ++ (if hostIsDarwin then [ "-DFFT_LIB=avtx" ] else [ ]);
        });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "fpcalc";
      # chromaprint ships no man page, so the man step warn-skips (nothing to
      # graft) and the binary carries no payload at all. binName drives that
      # (absent) lookup, not the chromaprint attr, so no pkgsAttr is needed.
      binName = "fpcalc";
      smoke = [ "-version" ];
      smokePattern = "fpcalc version 1\\.6";
      engine = "unpin-llvm";
      multicall = {
        # The `.exe` on the engine too, not the nixpkgs mingw-gcc cross.
        windows = true;
        programs = [{ name = "fpcalc"; }];
      };
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
