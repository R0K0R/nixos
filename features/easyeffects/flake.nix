{
  description = "EasyEffects preset collection";

  inputs.easyeffects-presets = {
    url = "github:JackHack96/EasyEffects-Presets";
    flake = false;
  };

  outputs = { easyeffects-presets, ... }: { presets = easyeffects-presets; };
}
