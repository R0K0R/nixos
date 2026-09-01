{ config, inputs, lib, pkgs, ... }:

{
  /*
    The niri-flake NixOS module installs niri, registers a display-manager
    session, polkit, portals, etc -- and declares the `niri-flake` and
    `programs.niri` options this feature writes to. Imported here rather than
    from a host file: `imports` cannot be gated, so a feature that writes an
    option must be the thing that brings that option into existence, or it
    breaks on every host that does not happen to import the module itself.
  */
  imports = [ inputs.feat-niri.nixosModule ];

  /*
    BROKEN AS OF THE 2026-08-31 NIXPKGS REBASE, and deliberately not repaired.

        error: `libdisplay-info_0_2` has been removed as it is was unused in
        Nixpkgs. Consider upgrading to `libdisplay-info_0_3` or
        `libdisplay-info` instead

    niri-flake's package still asks for the removed alias. It reproduces
    straight from the flake input -- `nix eval` on the niri package with none
    of this configuration involved -- so it is upstream's to fix, not a defect
    in this feature.

    THE ASSERTION BELOW DOES NOT ACTUALLY WIN THE RACE, measured rather than
    hoped: niri-flake's own module forces the package while assertions are
    still being collected, so `nix eval` on a niri host still dies with the
    libdisplay-info message and never reaches it. It is kept because it becomes
    correct the moment that changes, and because it states the fact next to the
    code it is about -- but the warning a person actually reads lives in the
    my.desktop.compositor description in features/compositor/nixos.nix.

    THE REST OF THE FEATURE IS KEPT INTACT AND IS KNOWN GOOD: its binds and
    settings still evaluate (verified against features/dms/compositor.nix,
    which contributes the shell half), so this is one broken dependency, not a
    feature to delete. Bump the niri input, drop this block, and it is live
    again.
  */
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.my.desktop.compositor != "niri";
          message = ''
            my.desktop.compositor = "niri" is currently unbuildable: niri-flake
            references libdisplay-info_0_2, which nixpkgs has removed. Not a
            configuration error -- see the note in features/niri/nixos.nix. Use
            "hyprland" until the niri input catches up.
          '';
        }
      ];
    }

    # Wayland compositor (niri) + graphical login.
    (lib.mkIf (config.my.desktop.compositor == "niri") {
      programs.niri = {
        enable = true;
        package = pkgs.niri-unstable;
      };

      # All packages get meteorlake-specific hashes; niri.cachix.org never hits.
      niri-flake.cache.enable = false;
    })
  ];
}
