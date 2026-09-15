/*
  KakaoTalk PC (the official Windows client) under Wine.

  WHY THE WINDOWS CLIENT AND NOT THE ANDROID ONE. Kakao allows one mobile
  device plus one PC at a time. The PC client is a COMPANION: it pairs against
  the account and coexists with the phone. The Android build is treated as a
  competing primary device -- logging into it under Waydroid evicts the phone,
  and the check is server-side over a pinned TLS channel, so there is nothing
  to configure around. That is why this is a wine package and not an APK.

  NOT REDISTRIBUTABLE. The installer is fetched from Kakao's own CDN at build
  time and pinned by hash; nothing proprietary is vendored into this repo.
*/
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  makeDesktopItem,
  copyDesktopItems,
  icoutils,
  bash,
  coreutils,
  findutils,
  nanum,
  /*
    REQUIRED, and it must come from a non-cross package set -- there is no
    sensible default to fall back on here, so this is deliberately not optional.

    Two independent constraints, either one fatal on its own:

    1. 32-bit. The client is a 32-bit binary (note the `win32` in Kakao's URL)
       and the launcher creates a win32 prefix, so wine must be a 32-bit build
       or carry WoW64. `wine64` alone cannot run it.
    2. Non-cross. 32-bit support pulls in pkgsi686Linux, whose gcc wants
       multilib, and gcc's builder asserts `!(enableMultilib && isCross)`. This
       tree is pseudo-cross -- build and host share the config triple, differing
       only by -march -- so isCross is true and evaluation fails outright.

    pkgsBuildBuild satisfies (2) but is still this tree's stdenv, so wine there
    rebuilds rustc, python3, perl and stdenv from source. features/kakaotalk
    passes upstream nixpkgs instead, which substitutes.
  */
  wine,
}:

let
  version = "26.8.0.5312";

  /*
    The URL carries no version: it always serves the current build, so the hash
    here is the only thing pinning it. When Kakao ships a release the fetch
    fails loudly with a hash mismatch, which is the intended behaviour -- run
    ./update.sh to re-pin. Last seen changing 2026-09-15.
  */
  installer = fetchurl {
    url = "https://app-pc.kakaocdn.net/talk/win32/KakaoTalk_Setup.exe";
    hash = "sha256-H3RL8CCEPgwXK7K/TRI+YiByzGdaeTrkSLjsx2LhU/g=";
  };

  /*
    A CURATED set of individual faces, not whole directories.

    Linking every .ttf/.otf/.ttc under nanum and noto-fonts-cjk-sans put 35
    files and 176 MB into the prefix, two of them ~30 MB variable-font CJK
    collections. Wine enumerates drive_c/windows/Fonts at startup and its GDI
    engine handles variable fonts poorly, and the host fontconfig already serves
    Noto Sans CJK KR for :lang=ko -- which wine reads -- so the bulk was
    redundant as well as slow.

    Four faces, ~17 MB: regular and bold of the two Nanum families that Korean
    Windows software actually asks for. Anything else still resolves through
    fontconfig.
  */
  fontFiles = [
    "${nanum}/share/fonts/NanumGothic.ttf"
    "${nanum}/share/fonts/NanumGothicBold.ttf"
    "${nanum}/share/fonts/NanumBarunGothic.ttf"
    "${nanum}/share/fonts/NanumBarunGothicBold.ttf"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "kakaotalk";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [
    makeWrapper
    copyDesktopItems
    icoutils
  ];

  desktopItems = [
    (makeDesktopItem {
      name = "kakaotalk";
      desktopName = "KakaoTalk";
      comment = "KakaoTalk PC client (Wine)";
      exec = "kakaotalk";
      icon = "kakaotalk";
      categories = [ "Network" "InstantMessaging" ];
      startupWMClass = "kakaotalk.exe";
    })
  ];

  installPhase = ''
    runHook preInstall

    install -Dm755 ${./launcher.sh} $out/bin/kakaotalk
    substituteInPlace $out/bin/kakaotalk \
      --replace-fail '@installer@' '${installer}' \
      --replace-fail '@version@'   '${version}' \
      --replace-fail '@fontFiles@' '${lib.concatStringsSep " " fontFiles}'

    wrapProgram $out/bin/kakaotalk \
      --prefix PATH : ${lib.makeBinPath [ wine coreutils findutils bash ]}

    # Icon straight out of the installer's resources, so the desktop entry does
    # not depend on shipping an image alongside it. Non-fatal: a missing icon is
    # a cosmetic defect, not a reason to fail the build.
    (
      mkdir -p icons && cd icons
      wrestool -x -t 14 ${installer} -o . 2>/dev/null || true
      icotool -x *.ico 2>/dev/null || true
      for png in *.png; do
        [ -e "$png" ] || continue
        size=$(echo "$png" | grep -oE '[0-9]+x[0-9]+' | head -1 || true)
        [ -n "$size" ] || continue
        install -Dm644 "$png" "$out/share/icons/hicolor/$size/apps/kakaotalk.png"
      done
    ) || true

    runHook postInstall
  '';

  passthru.installer = installer;

  meta = {
    description = "KakaoTalk PC client, run under Wine";
    homepage = "https://www.kakaocorp.com/page/service/service/KakaoTalk";
    # Kakao's own EULA; the installer is fetched from their CDN, never vendored.
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "kakaotalk";
  };
}
