/*
  Yulee (Ryzen 9900X) build-server settings. Accepts remote builds from laptops
  via the shared nix-remote-builder SSH key.
*/
{ ... }:

{
  nix.settings = {
    max-jobs = 12;
    trusted-users = [
      "root"
      "@wheel"
      "r0k0r"
    ];
    # Remote builds should fetch inputs from cache on Yulee's fast link, not via laptop SSH upload.
    substituters = [
      "https://cache.nixos.org"
      "https://niri.cachix.org"
    ];
  };

  users.users.r0k0r.openssh.authorizedKeys.keys = [
    (builtins.readFile ./nix-remote-builder.pub)
  ];
}
