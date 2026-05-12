{ inputs, ... }:

{
  imports = [
    inputs.dms.homeModules.dank-material-shell
    inputs.dms.homeModules.niri
    inputs.dms-plugin-registry.modules.default
    # niri-flake: NixOS module injects home-manager sharedModules (config); do not import homeModules.niri here.
  ];
}
