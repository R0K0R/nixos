# Brother DCP-T536DW CUPS driver (color ink-tank). nixpkgs has model-specific cups-brother-* drivers
# but NOT this model, so this packages Brother's own driver the exact way nixpkgs packages the sibling
# DCP-T720DW (pkgs/by-name/cu/cups-brother-dcpt720dw): extract the /opt/brother tree, point the perl
# wrapper + filter at the store copy, PATH-wrap them, patchelf the loader on the native filter binaries,
# and LD_PRELOAD libredirect so their hardcoded /opt reads hit $out/opt. The one difference from nixpkgs
# is the source: they fetchurl the i386 .deb from Brother's CDN (per-driver `dlfNNNNNN` url, not
# guessable for this model), so we vendor the x86_64 .rpm Benjamin downloaded and extract it with bsdtar
# (libarchive reads rpm). x86_64 (not i386) means no 32-bit libs needed. See the printer-setup memory.
{
  stdenv,
  lib,
  perl,
  ghostscript,
  coreutils,
  gnugrep,
  which,
  file,
  gnused,
  libarchive,
  makeBinaryWrapper,
  libredirect,
  debugLvl ? "0",
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "cups-brother-dcpt536dw";
  version = "3.6.1-2";

  # Vendored: Brother ships no stable fetchurl-able url for this model. x86_64 rpm, bsdtar-extracted.
  src = ./dcpt536dwpdrv-3.6.1-2.x86_64.rpm;

  strictDeps = true;
  buildInputs = [ perl ];
  nativeBuildInputs = [
    libarchive
    makeBinaryWrapper
  ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    bsdtar -xf $src -C $out   # the rpm's cpio payload unpacks to $out/opt/brother/...

    LPDDIR=$out/opt/brother/Printers/dcpt536dw/lpd
    WRAPPER=$out/opt/brother/Printers/dcpt536dw/cupswrapper/brother_lpdwrapper_dcpt536dw

    ln -s $LPDDIR/${stdenv.hostPlatform.linuxArch}/* $LPDDIR/

    substituteInPlace $WRAPPER \
      --replace-fail "PRINTER =~" "PRINTER = \"dcpt536dw\"; #" \
      --replace-fail "basedir =~" "basedir = \"$out/opt/brother/Printers/dcpt536dw/\"; #" \
      --replace-fail "lpdconf = " "lpdconf = \$lpddir.'/'.\$LPDCONFIGEXE.\$PRINTER; #" \
      --replace-fail "\$DEBUG=0;" "\$DEBUG=${debugLvl};"

    substituteInPlace $LPDDIR/filter_dcpt536dw \
      --replace-fail "BR_PRT_PATH =~" "BR_PRT_PATH = \"$out/opt/brother/Printers/dcpt536dw/\"; #" \
      --replace-fail "PRINTER =~" "PRINTER = \"dcpt536dw\"; #"

    wrapProgram $WRAPPER \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          gnugrep
          gnused
        ]
      }

    wrapProgram $LPDDIR/filter_dcpt536dw \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          ghostscript
          gnugrep
          gnused
          which
          file
        ]
      }

    # NB divergence from the nixpkgs dcpt720dw recipe: the T536DW's brdcpt536dwfilter is a C++ binary
    # and needs libstdc++ (the T720DW's needed only libc, so nixpkgs sets no rpath). Without an rpath
    # it fails `libstdc++.so.6 => not found`, the Brother wrapper swallows the error and exits 0, and
    # CUPS marks the job "completed" while NOTHING prints. So set an rpath to gcc's libs (libstdc++ +
    # libgcc_s); libc/libm resolve via the interpreter. rpath (not LD_LIBRARY_PATH) so it doesn't leak
    # into the ghostscript/perl the filter shells out to.
    patchelf --set-interpreter $(cat $NIX_CC/nix-support/dynamic-linker) \
      --set-rpath ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]} \
      $LPDDIR/brdcpt536dwfilter

    patchelf --set-interpreter $(cat $NIX_CC/nix-support/dynamic-linker) \
      --set-rpath ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]} \
      $LPDDIR/brprintconf_dcpt536dw

    wrapProgram $LPDDIR/brprintconf_dcpt536dw \
      --set LD_PRELOAD "${lib.getLib libredirect}/lib/libredirect.so" \
      --set NIX_REDIRECTS /opt=$out/opt

    wrapProgram $LPDDIR/brdcpt536dwfilter \
      --set LD_PRELOAD "${lib.getLib libredirect}/lib/libredirect.so" \
      --set NIX_REDIRECTS /opt=$out/opt

    mkdir -p "$out/lib/cups/filter" "$out/share/cups/model"

    ln -s $out/opt/brother/Printers/dcpt536dw/cupswrapper/brother_lpdwrapper_dcpt536dw \
      $out/lib/cups/filter/brother_lpdwrapper_dcpt536dw

    ln -s "$out/opt/brother/Printers/dcpt536dw/cupswrapper/brother_dcpt536dw_printer_en.ppd" \
      "$out/share/cups/model/"

    runHook postInstall
  '';

  meta = {
    description = "Brother DCP-T536DW printer driver";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    homepage = "http://www.brother.com/";
  };
})
