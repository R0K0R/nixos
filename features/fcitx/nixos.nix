{ config, lib, pkgs, ... }:

let
  cfg = config.my.fcitx;
in
{
  options.my.fcitx.enable =
    lib.mkEnableOption "fcitx5 input method (Hangul), Wayland-native, started as a user service";

  config = lib.mkIf cfg.enable {
    i18n.inputMethod = {
      enable = true;
      type = "fcitx5";
      # GTK3 immodule cache requires dlopen-ing HOST im-fcitx5.so at build time,
      # which fails in cross builds (exec stack / sandbox restrictions).
      # Wayland input method protocol makes the cache unnecessary anyway.
      enableGtk3 = false;
      fcitx5 = {
        waylandFrontend = true;
        addons =
          (
            with pkgs; [
              /* OnDemand hangul means the IME never registers until explicitly loaded —
                 fcitx then drops it from ~/.config/profile, so Alt_R has nothing to switch to.
                 Disable on-demand loading so Hangul joins the IME list at startup. */
              (fcitx5-hangul.overrideAttrs (old: {
                postInstall =
                  (old.postInstall or "")
                  + ''
                    substituteInPlace $out/share/fcitx5/addon/hangul.conf --replace-fail 'OnDemand=True' 'OnDemand=False'
                  '';
              }))
              fcitx5-gtk
            ]
          )
          ++ [
            pkgs.kdePackages.fcitx5-qt
          ];

        /*
          Global options + IME profile live in this feature's home.nix
          (~/.config/fcitx5/{config,profile}) so the user dir is the single
          source of truth instead of merging /etc vs ~/.config.
        */
      };
    };

    /* Niri pulls in xdg-desktop-autostart very early; fcitx5 often never stays up via the
       .desktop entry alone. Start it as a user service after graphical-session.target instead. */
    systemd.user.services.fcitx5-daemon = lib.mkIf (
      config.i18n.inputMethod.enable && config.i18n.inputMethod.type == "fcitx5"
    ) {
      description = "Fcitx 5 input method";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${config.i18n.inputMethod.package}/bin/fcitx5";
        Slice = "session.slice";
        Restart = "always";
        RestartSec = 5;
      };
      wantedBy = [ "graphical-session.target" ];
    };
  };
}
