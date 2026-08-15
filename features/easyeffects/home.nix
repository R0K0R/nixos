{ lib, inputs, osConfig, ... }:

lib.mkIf osConfig.my.easyeffects.enable {
  xdg.configFile."easyeffects/output" = {
    source = "${inputs.feat-easyeffects.presets}/output";
    recursive = true;
  };
}
