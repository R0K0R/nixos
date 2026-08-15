{ lib, ... }:

{
  /*
    Which Wayland compositor this host runs. Not an enable/disable switch: the
    niri and hyprland features both gate on this value, and the greeter and DMS
    read it to configure themselves, so exactly one compositor is selected
    system- and user-wide from a single line in the host file.

    This is the seed the whole my.* namespace grew from -- it was the only
    real option in the repo before the feature refactor.
  */
  options.my.desktop.compositor = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "niri" "hyprland" ]);
    default = null;
    description = ''
      Which Wayland compositor to enable system- and user-wide, or null for
      none.

      Nullable with a null default on purpose. This used to default to "niri",
      which was harmless only while the compositor modules were reachable from
      a single host's import list. Once every feature is registered on every
      host, that default meant a headless machine silently asked for niri --
      and the niri feature then tried to set `niri-flake.cache`, an option that
      only exists where the niri flake's module is imported. "No compositor" is
      a real state and has to be the one you get by not saying anything.
    '';
  };

  options.my.desktop.primaryOutput = lib.mkOption {
    type = lib.types.str;
    default = "eDP-1";
    example = "DP-1";
    description = ''
      Connector name of this machine's built-in/primary display.

      One option because it was hardcoded as "eDP-1" in three separate
      features -- niri's autorotate listener, hyprland's monitor line and its
      iio-hyprland invocation, and the DMS rotation-lock plugin's settings.
      Three copies of one fact about the hardware, which a host with a
      differently-named panel would have had to find and fix in all three.

      A fact, not a preference: it is determined by the machine, so it is
      declared once and read, rather than overridden per feature.
    '';
  };

  options.my.desktop.primaryOutputScale = lib.mkOption {
    type = lib.types.str;
    default = "1";
    example = "1.5";
    description = ''
      Fractional scale for the primary output, as literal text.

      A string rather than a float because it is interpolated straight into a
      compositor monitor spec, and Nix renders `toString 1.5` as "1.500000" --
      parseable, but a gratuitous change to the generated config for no gain.

      Compositors disagree on the auto-detected value for the same panel --
      Hyprland picked 2.0 where niri picked 1.5 -- so it is pinned rather than
      left to auto-detection, and it belongs to the machine, not the compositor.
    '';
  };
}
