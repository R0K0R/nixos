{ lib, pkgs, inputs, osConfig, ... }:

let
  cfg = osConfig.my.claude-code;

  # Same pinned claude-code the NixOS half installs (vendored package; binary
  # hash-pinned via the claude-code-bin flake input).
  claude-code = pkgs.callPackage ./package.nix { src = inputs.feat-claude-code.src; };

  gemma-claude = pkgs.writeScriptBin "gemma-claude" ''
    #! /bin/sh
    exec env \
      ANTHROPIC_BASE_URL=${cfg.gemma.baseURL} \
      ANTHROPIC_API_KEY=dummy \
      ANTHROPIC_DEFAULT_SONNET_MODEL=${cfg.gemma.sonnetModel} \
      ANTHROPIC_DEFAULT_HAIKU_MODEL=${cfg.gemma.sonnetModel} \
      ANTHROPIC_DEFAULT_OPUS_MODEL=${cfg.gemma.opusModel} \
      CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000 \
      ${claude-code}/bin/claude "$@"
  '';
in
lib.mkIf (cfg.enable && cfg.gemma.enable) {
  home.packages = [ gemma-claude ];
}
