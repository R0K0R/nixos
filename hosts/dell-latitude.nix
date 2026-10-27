/*
  benjamin on dell-latitude: the daily-driver bonfire Hyprland desktop.

  This is the user-level half of what hosts/dell-latitude/default.nix used to be in the old
  system flake: every `my.<feature>.enable` that only ever drove a home-manager half is a home
  module switch here. The system half (the compositor build, boot, greeter, services, fonts,
  udev, printers, the machine's output and scale) is the system flake's own dell-latitude host.

  Per-user package-set tuning: this host is untuned (plain upstream nixpkgs, everything from
  cache.nixos.org), so there is nothing to choose; my.tuning stays at its default.
*/
{ ... }:

{
  my = {
    fish.enable = true; # his fish config; the login shell is the system's
    # --- the bonfire desktop ---------------------------------------------------------------
    hyprland.enable = true;

    bonfire = {
      enable = true;
      # Drop "fastfetch" from the managed configs: the greeting is now modules/shell/fastfetch
      # (programs.fastfetch, with the bonfire logo), which owns ~/.config/fastfetch -- letting
      # bonfire also symlink a fastfetch config there would collide. (Default minus "fastfetch".)
      configNames = [ "waybar" "rofi" "swaync" "cava" "gtk.css" "xdg-desktop-portal" ];
    };

    flare.enable = true; # quickshell keystone notif panel
    panelbus.enable = true; # broadcast-on-open mutual exclusion for dock / notif

    # Right-edge cascade dock (SUPER+D shifts the pile, SUPER+SHIFT+D parks it):
    # sonora + KakaoTalk auto-route in; SUPER+SHIFT+T opens a docked
    # terminal; push any other window in with SUPER+ALT+D. See modules/desktop/pyre.
    pyre = {
      enable = true;
      # Bare regex bodies (each wrapped ^(...)$). Dots are left unescaped: a
      # backslash here would reach the generated Lua as an invalid string escape
      # (\.), and "." matching any char still matches the literal app-id fine.
      # kakaotalk.exe = EVERY KakaoTalk (Wine) window + its children/popups (they
      # all share the exe class); its own float rule in modules/desktop/hyprland is dropped
      # in favour of this route. The tray pill is class explorer.exe, NOT matched
      # here, so it stays with xembedsniproxy (see modules/apps/kakaotalk). NB the route
      # rule deliberately does NOT suppress activate -- that blocked KakaoTalk from
      # restoring its window from the tray (see the note in modules/desktop/pyre).
      apps = [ "sonora" "kakaotalk.exe" ];
    };

    settings.enable = true; # unified hearth settings store + generated schema (SETTINGS.md)
    lyre.enable = true; # headless PipeWire per-app/per-output EQ + routing engine
    trayApplets.enable = true; # nm-applet + blueman-applet

    # --- shell and editors -----------------------------------------------------------------
    fastfetch.enable = true; # system info with the bonfire logo (see REBRAND.md)
    fishTools.enable = true; # zoxide + fzf
    kitty.enable = true; # features/apps/kitty
    kittyLook.enable = true; # DepartureMono + 8 px margin, over the kitty feature
    starship.enable = true;
    eza.enable = true;
    cursor-theme.enable = true;
    ssh = {
      enable = true;
      # Interactive `ssh yulee`, as himself with his own key. yulee is in the
      # `injoystickly@` tailnet and this laptop is in `sihooleebd@`: a SHARED
      # node there, reachable by FQDN only.
      hosts.yulee = {
        HostName = "yulee.tail2d4da1.ts.net";
        User = "benjamin";
      };
    };
    fcitxTrayText.enable = true;
    neovim.enable = true;
    # Home halves of the system's base, fcitx and network (same names there).
    base.enable = true; # gh and its credential helper
    fcitx.enable = true;
    network.enable = true; # the KDE Connect daemon
    # Doom Emacs from his own config (the doom-private input); the Emacs build is the system's.
    emacs = {
      enable = true;
      font = {
        family = "DepartureMono Nerd Font";
        size = 16;
      };
    };

    # --- apps ------------------------------------------------------------------------------
    # KakaoTalk via Wine (galaxybook runs it via Waydroid instead).
    kakaotalk.enable = true;
    dolphin.enable = true;
    userPackages.enable = true;
    storytold.enable = true;
    fractionalScaleFix.enable = true; # the primary output runs at 0.8
    firefoxPortal.enable = true;
  };
}
