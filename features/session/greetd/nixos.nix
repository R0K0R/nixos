{ config, lib, ... }:

let
  cfg = config.my.greetd;
in
{
  options.my.greetd.enable =
    lib.mkEnableOption "greetd, the display manager that launches the compositor session";

  config = lib.mkMerge [
    # Depended upon by dms-greeter; see features/_meta.
    { my.internal.features.greetd.enabledBy = cfg.enable; }

    (lib.mkIf cfg.enable {
      services.greetd = {
        enable = true;
        settings.default_session.user = "greeter";
      };
    })
  ];
}
