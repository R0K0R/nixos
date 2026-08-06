{ pkgs, inputs, hostName, ... }:

let
  up = import ./user-packages.nix { inherit pkgs; };
  commonComplexPkgs = import ./common.nix { inherit pkgs inputs; };

  hostSysFile = ./hosts/${hostName}.nix;
  hostSysPkgs =
    if builtins.pathExists hostSysFile then import hostSysFile { inherit pkgs inputs; } else [ ];

  hostAccountFile = ./accounts/hosts/${hostName}.nix;
  hostAccountPkgs =
    if builtins.pathExists hostAccountFile then import hostAccountFile { inherit pkgs; } else [ ];
in
{
  environment.systemPackages =
    up.system.common ++ (up.system.${hostName} or [ ]) ++ hostSysPkgs ++ commonComplexPkgs;
  users.users.r0k0r.packages = up.account.common ++ (up.account.${hostName} or [ ]) ++ hostAccountPkgs;
}
