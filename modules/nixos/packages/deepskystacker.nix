{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  autoPatchelfHook,
  xcb-util-cursor,
  uchmviewer,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "deepskystacker";
  version = "6.2.0";

  src = fetchurl {
    url = "https://github.com/deepskystacker/DSS/releases/download/${finalAttrs.version}/DeepSkyStacker-${finalAttrs.version}-linux-x64-installer.run";
    hash = "sha256-FygbVwvA3Lh9SDx6jBqS3RqHbMSlFrkUD25IB5J2nOM=";
  };

  dontUnpack = true;

  nativeBuildInputs = [
    makeWrapper
    autoPatchelfHook
  ];

  buildInputs = [
    xcb-util-cursor
    uchmviewer
  ];

  installPhase = ''
    runHook preInstall

    cp "$src" installer.run
    chmod +x installer.run

    mkdir -p "$out"
    ./installer.run \
      --verbose \
      --target "$out" \
      --accept-licenses \
      --accept-messages \
      --confirm-command install

    mkdir -p "$out/bin"

    for prog in DeepSkyStacker DeepSkyStackerCL DeepSkyStackerLive; do
      if [ -x "$out/$prog" ]; then
        makeWrapper "$out/$prog" "$out/bin/$prog" \
          --prefix PATH : "${lib.makeBinPath [ uchmviewer ]}" \
          --prefix LD_LIBRARY_PATH : "$out/lib:$out/libexec"
      fi
    done

    if [ ! -x "$out/bin/DeepSkyStacker" ]; then
      echo "DeepSkyStacker binary not found after install" >&2
      find "$out" -maxdepth 3 -type f -executable
      exit 1
    fi

    ln -sfn "$out/bin/DeepSkyStacker" "$out/bin/deepskystacker"
    ln -sfn uchmviewer "$out/bin/kchmviewer"

    runHook postInstall
  '';

  meta = {
    description = "Astrophotography image stacking and processing";
    homepage = "https://deepskystacker.free.fr/";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "DeepSkyStacker";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
