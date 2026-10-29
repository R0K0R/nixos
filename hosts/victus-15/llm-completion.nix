# Code completion for Emacs (minuet) on the galaxybook, served from this
# machine's GPU: Qwen2.5-Coder 3B fine-tuned on Typst (~/git_shit/typst-fim:
# LoRA on 110M tokens -- GitHub Typst since 2024, Typst Universe, these notes,
# 21% other languages), at 6 bits (2.5 GB of the 4 GB card).  In the
# completion benchmark against the stock 1.5B at 8 bits: the same 11/40 exact,
# but closer misses (0.61 against 0.53) and Typst syntax right far more often
# (LaTeX to Typst 12/20 against 4/20).
#
# Listens on the Tailscale address only.  The firewall is off on this host and
# it also sits on school Wi-Fi, so 0.0.0.0 would serve the whole network.
{ lib, pkgs, ... }:

let
  # Not downloadable: it is trained on code without licences, so it stays
  # private.  The file goes into the store by hand, on whichever machine
  # builds this host, and is then found by its hash.
  model = pkgs.requireFile {
    name = "typst-coder-3b.Q6_K.gguf";
    hash = "sha256-16Oc9fr5lrSn2LqepabbvavKWjuq+A8OSNdcr1KcwN8=";
    message = ''
      The fine-tuned completion model is not in the store.  From yulee's
      ~/typst-fim/gguf/typst-coder-3b.Q6_K.gguf:
        nix-store --add-fixed sha256 typst-coder-3b.Q6_K.gguf
    '';
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
