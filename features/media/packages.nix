{ pkgs }:
{
  system = with pkgs; [
    ffmpeg-full

    # Generic MPRIS CLI. `dms ipc call mpris ...` already drives playback, but
    # it only exists while the shell is running and speaks DMS's own verbs.
    # playerctl talks to the session bus directly, so it works from scripts,
    # from a TTY, and against any player -- including the
    # org.mpris.MediaPlayer2.kdeconnect.mpris_* proxies KDE Connect publishes
    # for the phone and Waydroid.
    playerctl
    blender
    moonlight-qt

    # kdenlive needs rnnoise-plugin's LADSPA path wired in explicitly; the
    # plugin is built without LV2 (see tuning/overlays/pseudo-cross.nix, which
    # disables the LV2 helper because it is a HOST-compiled binary the BUILD
    # machine cannot run).
    (kdePackages.kdenlive.overrideAttrs (prev: {
      nativeBuildInputs = (prev.nativeBuildInputs or [ ]) ++ [ makeBinaryWrapper ];
      postInstall = (prev.postInstall or "") + ''
        wrapProgram $out/bin/kdenlive --prefix LADSPA_PATH : ${rnnoise-plugin}/lib/ladspa
      '';
    }))
  ];
}
