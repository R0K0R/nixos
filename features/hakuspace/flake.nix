{
  description = "Haku Space: the Waybar/Rofi/SwayNC desktop shell and its script suite";

  /*
    POINTS AT A LOCAL CHECKOUT, and must not stay that way.

    The declarative half of hakuspace -- packages.hakuspace and
    homeModules.hakuspace -- does not exist upstream yet. It was written for
    this feature and lives on the `pr/nix-home-module` branch of
    ~/hakuspace-contrib; upstream's own Nix support installs packages and
    system services but has never placed a dotfile, so there is nothing to
    consume until that lands.

    Swap this for `github:hakuimaku/hakuspace` once the PR is merged, or for
    the fork's URL to unblock a rebuild from another machine. An absolute
    path input is NOT reproducible: it locks with no narHash, so the flake
    evaluates differently -- or not at all -- anywhere that directory is
    missing. That is acceptable for a branch under review and for nothing
    else.
  */
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hakuspace = {
      url = "path:/home/r0k0r/hakuspace-contrib";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { hakuspace, ... }:
    {
      homeModule = hakuspace.homeModules.hakuspace;
    };
}
