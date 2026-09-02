{
  description = "Haku Space: the Waybar/Rofi/SwayNC desktop shell and its script suite";

  /*
    A FORK, PENDING UPSTREAM.

    The declarative half of hakuspace -- packages.hakuspace and
    homeModules.hakuspace -- does not exist upstream yet. Its own Nix support
    installs packages and system services but has never placed a dotfile,
    because those are copied by install.sh. So the package and the
    home-manager module were written for this feature and live on
    `pr/nix-home-module` of the fork, to be offered back.

    Point this at `github:hakuimaku/hakuspace` once that PR lands. Not before:
    the branch is what carries the module, and following the upstream default
    branch would silently lose it.

    A BRANCH REF, NOT A LOCAL PATH, and the difference matters. `path:` inputs
    lock with no narHash and no revision, so the flake evaluates differently --
    or not at all -- on any machine where that directory is missing, which is
    exactly the property a lock file exists to prevent. This locks to a commit
    like every other input here.

    nixpkgs is a LOCK-SLIMMING placeholder only. It does NOT decide what the
    package is built against: home.nix overrides programs.hakuspace.package
    with a host-pkgs callPackage, precisely because the flake default
    (self.packages, evaluated on this input's nixpkgs) built against the wrong
    set on every host -- see the comment on that override. The follows exists
    so the lock does not pin, and evaluation does not fetch, the nixos-26.05
    the upstream flake declares for its own standalone use.
  */
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hakuspace = {
      url = "github:R0K0R/hakuspace/pr/nix-home-module";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { hakuspace, ... }:
    {
      homeModule = hakuspace.homeModules.hakuspace;
    };
}
