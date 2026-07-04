{ pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    vim
    tailscale
    nbfc-linux
    ryzenadj
    gh
  ] ++ (import ../../modules/nixos/packages/common.nix { inherit pkgs; });
}
