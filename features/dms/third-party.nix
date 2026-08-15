{ inputs, ... }:

{
  imports = [
    inputs.dms.homeModules.dank-material-shell
    inputs.dms.homeModules.niri
    # dms-plugin-registry split its single `modules` output into homeModules/nixosModules.
    inputs.dms-plugin-registry.homeModules.default
    # niri-flake: NixOS module injects home-manager sharedModules (config); do not import homeModules.niri here.
  ];
}
