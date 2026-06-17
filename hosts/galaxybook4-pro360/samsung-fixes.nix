# Samsung Galaxy Book4 Pro 360 — speakers + internal mic.
# https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes
# Webcam: see webcam.nix

{ inputs, lib, ... }:

let
  fixes = inputs.samsung-galaxy-book-linux-fixes;
in
{
  imports = [
    "${fixes}/nixos/samsung-speaker-fix.nix"
  ];

  hardware.samsungGalaxyBook.speakerFix = {
    source = "local";
    localSrc = "${fixes}/speaker-fix/src";
  };

  boot.extraModprobeConfig = lib.mkAfter ''
    # Galaxy Book4 internal mic (mic-fix)
    options snd-intel-dspcfg dsp_driver=3
  '';
}
