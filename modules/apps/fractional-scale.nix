{ config, lib, pkgs, ... }:

let
  cfg = config.my.fractionalScaleFix;

  flag = "--disable-features=WaylandFractionalScaleV1";

  /*
    Wrap a PATH-resolved binary of an already-built package. Used for discord, whose launcher
    (a bare `Exec=Discord` .desktop) resolves through PATH, so a symlinkJoin over its binaries IS
    what the launcher and rofi run.
  */
  noFracScale = pkg: bins: pkgs.symlinkJoin {
    name = "${lib.getName pkg}-nofracscale";
    paths = [ pkg ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = lib.concatMapStringsSep "\n"
      (b: ''wrapProgram $out/bin/${b} --add-flags "${flag}"'')
      bins;
  };
in
{
  options.my.fractionalScaleFix.enable = lib.mkEnableOption ''
    --disable-features=WaylandFractionalScaleV1 for the Chromium/Electron apps (Chrome, Discord,
    Claude Desktop), for a monitor scaled BELOW 1 (this desktop runs 0.8)
  '';

  config = lib.mkIf cfg.enable {
    /*
      At a fractional DOWNSCALE (primary output scale 0.8), Chromium/Electron apps whose
      fractional-scale path (WaylandFractionalScaleV1, ON by default) build a physical-sized buffer
      but fill only the scale-FRACTION of their window -- so they render into the top-left ~0.8 of
      the frame ("smaller than the screen"). Disabling the feature drops Chromium to integer
      buffer_scale=1: it renders at the LOGICAL window size and Hyprland downscales the whole
      window -> full-bleed at any scale.

      Two mechanisms, because the launch path differs per app:
        - google-chrome has a native `commandLineArgs` hook AND its .desktop Exec is an ABSOLUTE
          store path, so a symlinkJoin wrapper would be bypassed -- the .override regenerates both
          the binary and the .desktop, so rofi/menu launches pick up the flag.
        - discord has no such hook and a PATH-resolved bare `Exec=Discord`, so the wrapper above IS
          what the launcher resolves.
        - Claude Desktop is installed by the SYSTEM (its package bakes in its own wrapper, whose
          .desktop Exec is an absolute store path into the system's copy), and a home cannot reach
          into that package. The flag is added from outside: a `claude-desktop` shim earlier on
          PATH and a user .desktop entry that runs it (XDG_DATA_HOME wins over the system's entry).
          Chromium takes the last occurrence of a switch, and the system's wrapper only passes
          --enable-features, so appending ours is safe. The tidier fix is a flag option on the
          system's claude-desktop feature; see README.md, "What the system must provide".
    */
    home.packages = [
      (pkgs.google-chrome.override { commandLineArgs = flag; })
      (noFracScale pkgs.discord [ "discord" "Discord" ])
      (pkgs.writeShellScriptBin "claude-desktop" ''
        # The system's claude-desktop, found past this shim on the system PATH.
        for d in /run/current-system/sw/bin /etc/profiles/per-user/${config.home.username}/bin; do
          [ -x "$d/claude-desktop" ] && exec "$d/claude-desktop" ${flag} "$@"
        done
        echo "claude-desktop: not installed on this system" >&2
        exit 127
      '')
    ];

    xdg.desktopEntries."com.anthropic.Claude" = {
      name = "Claude";
      comment = "Claude Desktop";
      exec = "claude-desktop %u";
      icon = "claude-desktop";
      terminal = false;
      categories = [ "Network" "Utility" ];
      mimeType = [ "x-scheme-handler/claude" ];
    };
  };
}
