{ pkgs, inputs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    vim
    git
    tailscale
    nbfc-linux
    ryzenadj
    gh
  ] ++ (import ../../modules/nixos/packages/common.nix { inherit pkgs inputs; });
}
