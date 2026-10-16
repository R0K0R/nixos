{ config, lib, ... }:

let
  cfg = config.my.pipewire;
in
{
  options.my.pipewire.enable =
    lib.mkEnableOption "PipeWire audio with the PulseAudio compatibility server";

  config = lib.mkIf cfg.enable {
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };
}
