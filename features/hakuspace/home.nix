{ config, lib, pkgs, osConfig, inputs, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "hakuspace"; };
  cfg = osConfig.my.hakuspace;
  enabled = cfg.enable && inScope;

  bin = name: "${config.home.homeDirectory}/.local/bin/${name}";

  /*
    One shape per component, because they all want the same lifecycle: tied to
    graphical-session.target, started after it, stopped with it.

    SYSTEMD RATHER THAN THE COMPOSITOR'S AUTOSTART, which is how upstream does
    it (src/wm/hyprland/config/autostart.lua runs eleven hl.exec_cmd calls on
    hyprland.start). That file is not installed here -- features/hyprland owns
    the Hyprland config -- and features/hyprland states the rule directly:
    nothing is spawned from the compositor, least of all a shell, because a
    config reload re-executes the whole Lua script and an exec-once copy
    becomes a second unmanaged instance. Units also restart on failure, which
    an exec_cmd cannot.
  */
  service = description: exec: {
    Unit = {
      Description = description;
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = exec;
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  oneshot = description: exec: {
    Unit = {
      Description = description;
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = exec;
    };
  };
in
{
  imports = [
    inputs.feat-hakuspace.homeModule
    ./compositor.nix
  ];

  config = lib.mkIf enabled {
    programs.hakuspace = {
      enable = true;
      inherit (cfg) configNames;

      /*
        NULL, deliberately: this is what keeps the two halves separable.

        hakuspace ships a COMPLETE Hyprland config -- monitors, input, layout,
        animations, rules, autostart, keybinds. Installing it would put a
        second full config at ~/.config/hypr, which features/hyprland already
        owns, and undo the separation between compositor and shell. Only the
        shell half is taken; the keybinds it needs are contributed to whichever
        compositor is selected from ./compositor.nix.
      */
      compositor = null;

      # playerctl for the music module: upstream assumes a system-wide install,
      # and the wrapper in the package cannot know about it.
      extraScriptPath = [ pkgs.playerctl ];
    };

    /*
      The components upstream's autostart.lua launches, minus everything this
      configuration already owns.

      DROPPED, and each for a reason rather than as a trim:
        polkit_start.sh    features/session-services runs an agent already
        nm-applet          features/network owns NetworkManager and its tray
        blueman-applet     likewise for bluetooth
        fcitx5 -d          features/fcitx starts it as its own user service
        welcome.sh         a first-run greeting popup, not a session component
        desktop_icons      upstream marks it experimental and buggy
    */
    systemd.user.services = {
      hakuspace-wallpaper = service "Haku Space wallpaper daemon" "awww-daemon";
      hakuspace-notifications = service "Haku Space notification centre" "swaync";
      hakuspace-idle = service "Haku Space idle daemon" "hypridle";

      # Two watchers, not one: cliphist stores text and images through separate
      # wl-paste subscriptions and a single --watch handles one MIME class.
      hakuspace-clipboard-text = service "Haku Space clipboard history (text)"
        "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store";
      hakuspace-clipboard-image = service "Haku Space clipboard history (images)"
        "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store";

      /*
        waybar_manager.sh, not waybar, and oneshot rather than a supervised
        service. The script is what decides WHICH layout is live: it symlinks
        the selected layout's config and style.css into ~/.config/waybar and
        only then starts waybar (`if ! pgrep -x waybar; then waybar &`).
        Supervising waybar directly would start it before any layout had been
        chosen -- and on a first login there is no config to read at all.
      */
      hakuspace-bar = oneshot "Haku Space bar" (bin "waybar_manager.sh");
      hakuspace-dockbar = oneshot "Haku Space dockbar" "${bin "dockbar_manager.sh"} --startup";
    };
  };
}
