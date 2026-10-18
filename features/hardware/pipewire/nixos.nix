{ config, lib, ... }:

let
  cfg = config.my.pipewire;
in
{
  options.my.pipewire.enable =
    lib.mkEnableOption "PipeWire audio with the PulseAudio compatibility server";

  config = lib.mkIf cfg.enable {
    my.state.user.state.directories = [
      ".local/state/wireplumber" # default sink/source and per-stream volumes
    ];
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };
  };
}
