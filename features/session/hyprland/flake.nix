{
  description = "Hyprland source: the R0K0R/Hyprland fork";

  /*
    Hyprland is built from a fork instead of nixpkgs' tag plus a stack of patch
    files (github.com/R0K0R/Hyprland, laid out like the nixpkgs fork):

      pr/<name>   one bug fix each, on the tag nixpkgs packages -- the unit
                  that goes upstream
      nixos       the tag + every pr/* fix, linear: the hosts' compositor
      keystone    nixos + the side-dock series (rendering, scale-to-fit,
                  input, gestures, Lua touch/pen; one commit per concern):
                  a home's compositor (r0k0r's my.hyprland.keystone), so
                  an input of that home, not of this flake

    Change Hyprland in the fork (fix the commit that owns the concern), push,
    then `nix flake update feat-hyprland`. Pinned by branch in the URL --
    flake = false inputs do not accept ref/rev -- and locked to a commit.
  */
  inputs.hyprland-nixos = {
    url = "github:R0K0R/Hyprland/nixos";
    flake = false;
  };

  outputs =
    { hyprland-nixos, ... }:
    {
      src = {
        nixos = hyprland-nixos;
      };
    };
}
