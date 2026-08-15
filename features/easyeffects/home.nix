{ lib, inputs, osConfig, ... }:

lib.mkIf osConfig.my.easyeffects.enable {
  xdg.configFile."easyeffects/output" = {
    source = "${inputs.easyeffects-presets}/output";
    recursive = true;
  };
}
