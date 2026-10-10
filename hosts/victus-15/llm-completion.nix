# Code completion for Emacs (minuet) on the galaxybook, served from this
# machine's GPU: Qwen2.5-Coder 1.5B, the best of the local models in the Typst
# completion benchmark (9/40 exact, ~0.2 s on the RTX 3050) and the one that
# fits a 4 GB card whole.
#
# Listens on the Tailscale address only.  The firewall is off on this host and
# it also sits on school Wi-Fi, so 0.0.0.0 would serve the whole network.
{ lib, pkgs, ... }:

let
  # Pinned to the Hugging Face commit the benchmark used.
  model = pkgs.fetchurl {
    url = "https://huggingface.co/QuantFactory/Qwen2.5-Coder-1.5B-GGUF/resolve/73c3c696087d8d57a3005e31f2afe78f43059739/Qwen2.5-Coder-1.5B.Q4_K_M.gguf";
    hash = "sha256-qcy2voAkEuYeGsvuYoeiOxHlbpRxhWD5EAdcZLYZSRA=";
  };
in
{
  services.llama-cpp = {
    enable = true;
    settings = {
      host = "100.64.0.2";
      port = 8012;
      inherit model;
      n-gpu-layers = 99;
      ctx-size = 4096;
      no-webui = true;
    };
  };

  # The Tailscale address does not exist until tailscaled has brought the
  # interface up; until then binding it fails, so retry soon rather than after
  # the module's five minutes. mkForce: the module sets its 300 at normal
  # priority since nixpkgs e7439b6, and two plain values conflict.
  systemd.services.llama-cpp = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    serviceConfig.RestartSec = lib.mkForce 10;
  };
}
