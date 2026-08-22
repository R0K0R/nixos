{ config, lib, inputs, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.easyeffects.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "easyeffects"; };
in
lib.mkIf (osConfig.my.easyeffects.enable && inScope) {
  xdg.configFile."easyeffects/output" = {
    source = "${inputs.feat-easyeffects.presets}/output";
    recursive = true;
  };
}
