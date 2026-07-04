{ pkgs, inputs, hostName, ... }:

let
  hostSysFile = ./hosts/${hostName}.nix;
  hostSysPkgs = if builtins.pathExists hostSysFile then import hostSysFile { inherit pkgs; } else [ ];

  accountCommon = import ./accounts/r0k0r.nix { inherit pkgs; };

  hostAccountFile = ./accounts/hosts/${hostName}.nix;
  hostAccountPkgs =
    if builtins.pathExists hostAccountFile then import hostAccountFile { inherit pkgs; } else [ ];
in
{
  environment.systemPackages = (import ./common.nix { inherit pkgs inputs; }) ++ hostSysPkgs;
  users.users.r0k0r.packages = accountCommon ++ hostAccountPkgs;
}
