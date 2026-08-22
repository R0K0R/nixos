{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.dms;
in
{
  # The greeter moved out of dms itself into its own repo/module. Imported
  # unconditionally: `imports` cannot be gated, and an unenabled module costs
  # only its option declarations.
  imports = [ inputs.feat-dms.greeterModule ];

  options.my.dms = {
    enable = lib.mkEnableOption ''
      DankMaterialShell: the desktop shell (bar, dock, launcher, lock screen).
      The shell itself is configured in this feature's home half
    '';

    settingsOverride = lib.mkOption {
      type = lib.types.either (lib.types.attrsOf lib.types.anything) (
        lib.types.functionTo (lib.types.attrsOf lib.types.anything)
      );
      default = { };
      example = lib.literalExpression ''{ showBattery = false; fontScale = 1.2; }'';
      description = ''
        Per-host changes merged over ./settings.nix with `recursiveUpdate`.
        Empty means "exactly settings.nix", so a host that says nothing gets the
        shared config unchanged.

        This is the RIGHT tool for anything that is a preference rather than a
        fact: greeterWallpaperPath, currentThemeName, fontFamily, fontScale,
        popupTransparency, iconTheme. Those differ between machines by taste --
        a bigger panel wants a different fontScale, a different machine wants a
        different wallpaper -- and there is nothing in the config they could
        ever be derived from, because no fact determines them.

        The one anti-pattern is overriding something the host ALREADY declares
        elsewhere. `enableFprint` is derived in home.nix from
        services.fprintd.enable instead of being overridden here, because those
        are two names for one fact and two copies of a fact can drift. If a
        value has a real source, read it; if it is taste, put it here.

        Two accepted shapes:

          ATTRSET -- merged with `recursiveUpdate`. Nested attrsets merge
          partially, so `cursorSettings.size = 16` keeps `cursorSettings.theme`.
          This is what you want almost always.

          FUNCTION -- `prev: prev // { ... }`, given the fully-derived settings
          and returning the final set. The escape hatch for LISTS, which
          `recursiveUpdate` replaces wholesale rather than merging. The lists
          that matter are big: `barConfigs` is ~84 lines, plus
          `controlCenterWidgets`, `appIdSubstitutions`, `powerMenuActions`.
          Restating a whole bar in a host file to change one transparency would
          defeat the point, so a function can edit them in place:

            settingsOverride = prev: prev // {
              barConfigs = map (b: b // { transparency = 0.5; }) prev.barConfigs;
            };
      '';
    };

    greeter = {
      enable = lib.mkEnableOption "the DMS login greeter (dank-greeter, a separate upstream repo)";

      primaryLogin = lib.mkOption {
        type = lib.types.str;
        default = config.my.internal.primaryUser;
        defaultText = lib.literalExpression "the primary user";
        description = ''
          Whose home directory the greeter reads theme state from, so the login
          screen matches the desktop.
        '';
      };
    };
  };

  # Accounts this feature applies to; defaults to the primary user.
  options.my.dms.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkMerge [
    {
      my.internal.features.dms = {
        # The shell reads my.desktop.compositor for its workspace and bar
        # integration; with no compositor selected it has nothing to attach to.
        requires = [ "compositor" ];
        enabledBy = cfg.enable;
      };

      my.internal.features."dms.greeter" = {
        # The greeter IS a greetd session. Without greetd it is built, installed,
        # and never launched -- no error anywhere.
        requires = [ "greetd" ];
        enabledBy = cfg.greeter.enable;
      };
    }

    (lib.mkIf cfg.greeter.enable {
    programs.dms-greeter = {
      enable = true;
      # The greeter has to launch the same compositor the session uses, so it
      # reads the single host-level choice rather than duplicating it.
      compositor.name = config.my.desktop.compositor;

      configHome = config.users.users.${cfg.greeter.primaryLogin}.home;

      logs = {
        save = true;
        path = "/tmp/dms-greeter.log";
      };

      quickshell.package = pkgs.quickshell;
    };
    })
  ];
}
