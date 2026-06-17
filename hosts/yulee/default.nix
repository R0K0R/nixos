{ lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/system/state-version.nix
    ../../modules/nixos/users/r0k0r.nix
    ../../modules/nixos/nix/flake-settings.nix
    ../../modules/nixos/nix/yulee-builder-server.nix
  ];

  networking.hostName = "yulee";

  services.openssh.enable = true;

  nixpkgs.hostPlatform = lib.systems.elaborate {
    system = "x86_64-linux";
    gcc.arch = "znver5";
  };
}
