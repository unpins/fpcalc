{
  description = "fpcalc (Chromaprint audio fingerprinter) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # Chromaprint ships one program, `fpcalc`: it decodes audio with FFmpeg and
  # fingerprints it. FFmpeg is the catalog's own build (nix-lib ffmpeg.nix,
  # the one the `ffmpeg` package ships), so fpcalc reads every format, codec
  # and protocol `ffmpeg` does.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # `sp` is the static package set for the target (pkgsStatic or
      # mingwStaticCross); `ff` the catalog FFmpeg with its libraries.
      # withExamples drops the demo binaries; withTools (default) keeps fpcalc.
      mk = { sp, ff }:
        let
          chromaprint = sp.chromaprint;
          host = chromaprint.stdenv.hostPlatform;
          hostIsDarwin = host.isDarwin or false;
          # "can this host run what it just built" — true on the three native
          # CI jobs and on i686 built on x86_64, false on the other crosses.
          canRun = chromaprint.stdenv.buildPlatform.canExecute host;
        in
        (chromaprint.override ({
          ffmpeg-headless = ff;
          withExamples = false;
        })).overrideAttrs (old: {
          # Upstream's suite is 98 unit tests plus a fingerprint of a real
          # 9 MB recording compared against a known hash. It passes under
          # static musl and the engine and runs in milliseconds.
          doCheck = canRun;
          # chromaprint links FFmpeg's .a files by path, without the codec
          # libraries behind them; append those at the end of the link line.
          # FFmpeg's .pc names some of them bare (-lmp3lame, -lpthread), so
          # FFmpeg's own inputs go on the search path too.
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ sp.buildPackages.pkg-config ];
          buildInputs = (old.buildInputs or [ ]) ++ ff.buildInputs;
          preConfigure = (old.preConfigure or "") + ''
            cmakeFlagsArray+=("-DCMAKE_CXX_STANDARD_LIBRARIES=$($PKG_CONFIG --static --libs libavformat libavcodec libswresample libavutil)")
          '';
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
          # Accelerate via SDKROOT.
          cmakeFlags = (old.cmakeFlags or [ ])
            ++ (if hostIsDarwin then [ "-DFFT_LIB=avtx" ] else [ ]);
        });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "fpcalc";
      dnsFallback = true; # reads http(s) URLs; opt into the Android DNS fallback
      # chromaprint ships no man page, so the binary carries no payload at all.
      smoke = [ "-version" ];
      smokePattern = "fpcalc version 1\\.6";
      engine = "unpin-llvm";
      multicall = {
        # The `.exe` on the engine too, not the nixpkgs mingw-gcc cross.
        windows = true;
        programs = [{ name = "fpcalc"; }];
        # FFmpeg's darwin backends and its text-rendering chain.
        requires.frameworks = ulib.unpinFfmpeg.darwinFrameworks;
        removeReferences = ulib.unpinFfmpeg.deadRefs;
      };
      build = pkgs: mk {
        sp = pkgs.pkgsStatic;
        ff = ulib.unpinFfmpeg.libs.native pkgs;
      };
      windowsBuild = pkgs: mk {
        sp = ulib.mingwStaticCross pkgs;
        ff = ulib.unpinFfmpeg.libs.windows pkgs;
      };
    };
}
