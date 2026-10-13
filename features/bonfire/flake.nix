{
  description = "Bonfire Space: the Waybar/Rofi/SwayNC desktop shell and its script suite";

  /*
    OUR FORK of the desktop shell.

    bonfire (the shell: waybar/rofi/swaync + its script suite) began as the
    unmaintained R0K0R/hakuspace -- itself a "nixified" fork of hakuimaku/hakuspace.
    We adopted it as sihooleebd/bonfire and rebranded it end to end (hakuspace ->
    bonfire; see REBRAND.md). The declarative half -- packages.bonfire and
    homeModules.bonfire -- lives there: the package wraps the scripts' deps onto
    PATH and the home-manager module links the tree into ~/.config (upstream only
    ever copied dotfiles via install.sh, which a Nix-managed machine cannot
    reproduce).

    A BRANCH/COMMIT REF, NOT A LOCAL PATH, and the difference matters. `path:`
    inputs lock with no narHash and no revision, so the flake evaluates
    differently -- or not at all -- on any machine where that directory is
    missing, which is exactly the property a lock file exists to prevent. This
    locks to a commit like every other input here.

    nixpkgs is a LOCK-SLIMMING placeholder only. It does NOT decide what the
    package is built against: home.nix overrides programs.bonfire.package with a
    host-pkgs callPackage, precisely because the flake default (self.packages,
    evaluated on this input's nixpkgs) built against the wrong set on every host
    -- see the comment on that override. The follows exists so the lock does not
    pin, and evaluation does not fetch, the nixos-26.05 the shell's own flake
    declares for its standalone use.
  */
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    bonfire = {
      # The shell -- our fork + full rebrand of the unmaintained R0K0R/hakuspace. See REBRAND.md.
      url = "github:sihooleebd/bonfire";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { bonfire, ... }:
    {
      homeModule = bonfire.homeModules.bonfire;
    };
}
