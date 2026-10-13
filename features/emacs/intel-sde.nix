/*
  Intel Software Development Emulator: runs x86 code for a CPU the machine
  does not have (sde64 -mtl -- prog emulates Meteor Lake, GFNI and AVX-VNNI
  included) by JIT-translating it under Pin. Children of an emulated process,
  forked or exec'd, are emulated too.

  Prebuilt and unfree (Intel's license agreement). Only the 64-bit runtime is
  kept: pinkit is the kit for writing Pin tools (156M), ia32 and the 32-bit
  sde/xed launchers serve 32-bit programs, doc is HTML. Interpreters are
  pointed at this package set's glibc; nothing else needs patching, the
  runtime brings its own libraries.

  Call it from a package set whose code runs on any x86_64 machine
  (buildPackages under IntraISACross): sde64 is what runs natively, so it must
  not itself need the CPU it emulates.
*/
{
  lib,
  stdenv,
  fetchurl,
  patchelf,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "intel-sde";
  version = "10.13.1";

  src = fetchurl {
    # The id in the path is Intel's per-release mirror directory.
    url = "https://downloadmirror.intel.com/924984/sde-external-${finalAttrs.version}-2026-07-28-lin.tar.xz";
    hash = "sha256-lOl9Yj/sVDhWhuHnumXryZQXSMBe5FFCOUgzSJK/K1A=";
  };

  nativeBuildInputs = [ patchelf ];

  dontConfigure = true;
  dontBuild = true;
  # Pin checks its own binaries; stripping or patchelf --shrink-rpath would
  # alter them.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/sde $out/bin
    cp -a sde64 pin intel64 misc Licenses README.txt $out/libexec/sde/
    find $out/libexec/sde -type f | while read -r f; do
      if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
        patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$f"
      fi
    done
    ln -s ../libexec/sde/sde64 $out/bin/sde64

    runHook postInstall
  '';

  meta = {
    description = "Intel Software Development Emulator";
    homepage = "https://www.intel.com/content/www/us/en/developer/articles/tool/software-development-emulator.html";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
