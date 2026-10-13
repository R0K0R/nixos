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
    # kdenlive REMOVED 2026-10-10 -> replaced by FilmCraft (flatpak ai.storyteller.filmcraft,
    # installed --user from the unofficial `artcraft` (FlatPark) remote; see the craft-suite memory).
    # To revert: restore the kdenlive overrideAttrs block from git -- it wired rnnoise-plugin's LADSPA
    # path in (plugin built without LV2 per tuning/overlays/pseudo-cross.nix) + makeBinaryWrapper.
  ];
}
