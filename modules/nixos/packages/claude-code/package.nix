# Vendored from nixpkgs' pkgs/by-name/cl/claude-code (trimmed to Linux), so
# the version is OUR choice, not nixpkgs' packaging cadence: Anthropic's
# native release channel (downloads.claude.ai) carries every version the
# moment it ships. Pin lives in ./manifest.json; bump with ./update.sh
# (optionally passing an explicit version).
{
  lib,
  stdenvNoCC,
  fetchurl,
  installShellFiles,
  makeBinaryWrapper,
  autoPatchelfHook,
  alsa-lib,
  procps,
  ripgrep,
  bubblewrap,
  socat,
  versionCheckHook,
  writableTmpDirAsHomeHook,
}:
let
  stdenv = stdenvNoCC;
  baseUrl = "https://downloads.claude.ai/claude-code-releases";
  manifest = lib.importJSON ./manifest.json;
  platformKey = "${stdenv.hostPlatform.node.platform}-${stdenv.hostPlatform.node.arch}";
  platformManifestEntry = manifest.platforms.${platformKey};
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-code";
  inherit (manifest) version;

  src = fetchurl {
    url = "${baseUrl}/${finalAttrs.version}/${platformKey}/claude";
    sha256 = platformManifestEntry.checksum;
  };

  dontUnpack = true;
  dontBuild = true;
  # otherwise the bun runtime is executed instead of the binary
  dontStrip = true;

  nativeBuildInputs = [
    installShellFiles
    makeBinaryWrapper
    autoPatchelfHook
  ];

  strictDeps = true;

  installPhase = ''
    runHook preInstall

    installBin $src

    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --set-default FORCE_AUTOUPDATE_PLUGINS 1 \
      --set DISABLE_INSTALLATION_CHECKS 1 \
      --set USE_BUILTIN_RIPGREP 0 \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ alsa-lib ]} \
      --prefix PATH : ${
        lib.makeBinPath [
          # node-tree-kill needs ps on linux
          procps
          ripgrep
          # sandbox support
          bubblewrap
          socat
        ]
      }

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Agentic coding tool that lives in your terminal";
    homepage = "https://github.com/anthropics/claude-code";
    changelog = "https://github.com/anthropics/claude-code/blob/v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "claude";
  };
})
