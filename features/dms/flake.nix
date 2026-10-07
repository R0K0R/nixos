{
  description = "DankMaterialShell: the desktop shell, its greeter and its plugin registry";

  /*
    All three of DMS's upstreams, owned by the feature that consumes them. This
    is what the plan meant by giftable: `rm -r features/dms` takes the shell,
    the greeter, the plugin registry and their pins with it, and the root flake
    stops carrying pins for a shell it no longer has.

    Two-level follows -- see features/niri/flake.nix for why both halves are
    required and what goes wrong when one is missing.
  */
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    dms = {
      url = "github:AvengeMedia/DankMaterialShell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The greeter split out of dms itself into its own repo.
    dank-greeter = {
      url = "github:AvengeMedia/dank-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms-plugin-registry = {
      url = "github:AvengeMedia/dms-plugin-registry";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    /*
      Our own plugin, pinned like any other upstream rather than vendored as a
      directory in this repo. It lives here and not in the root flake for the
      same reason the three above do: it is a DMS thing, so `rm -r features/dms`
      should take its pin with it.

      flake = false -- the repo is plugin sources (plugin.json, QML, the
      accelerometer helper), not a flake. What comes through is the store path
      of the checkout, which is exactly what
      programs.dank-material-shell.plugins.<name>.src wants.
    */
    vehicle-motion-cues = {
      url = "github:R0K0R/vehicle_motion_cues_dms";
      flake = false;
    };

    # Same shape: bar widget + daemon that hands a screenshot to a background
    # Claude Code session and shows its (hint-only, LaTeX) reply.
    claude-helper = {
      url = "github:R0K0R/dms_claude_helper";
      flake = false;
    };

    # Bar stopwatch: icon -> running time -> paused -> resume/reset popup.
    stopwatch = {
      url = "github:R0K0R/dms_stopwatch_bar";
      flake = false;
    };
  };

  outputs =
    { dms, dank-greeter, dms-plugin-registry, vehicle-motion-cues, claude-helper, stopwatch, ... }:
    {
      greeterModule = dank-greeter.nixosModules.default;

      # Plugin sources this feature pins, for plugins.nix to point `src` at.
      # An attrset rather than a bare path so adding a second plugin later does
      # not change the shape of what consumers read.
      pluginSources = {
        vehicleMotionCues = vehicle-motion-cues;
        claudeHelper = claude-helper;
        inherit stopwatch;
      };
      homeModules = [
        dms.homeModules.dank-material-shell
        dms.homeModules.niri
        # dms-plugin-registry split its single `modules` output into
        # homeModules/nixosModules.
        dms-plugin-registry.homeModules.default
      ];
    };
}
