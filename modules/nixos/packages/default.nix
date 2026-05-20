{ pkgs, hostName, ... }:

let
  hostFile = ./hosts/${hostName}.nix;
  hostPkgs = if builtins.pathExists hostFile then import hostFile { inherit pkgs; } else [ ];
  accountPkgs = import ./accounts/r0k0r.nix { inherit pkgs; };
in
{
  environment.systemPackages = (import ./common.nix { inherit pkgs; }) ++ hostPkgs;
  users.users.r0k0r.packages = accountPkgs;
}
