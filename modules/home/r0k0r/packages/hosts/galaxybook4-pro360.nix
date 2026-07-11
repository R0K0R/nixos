{ pkgs, inputs, ... }:

let
  # Same pinned claude-code as modules/nixos/packages/common.nix -- without
  # this, ${claude-code} resolves to the fork's package set and gets built
  # from source with the patched stdenv instead of substituted.
  claude-code = (import inputs.nixpkgs-claude {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  }).claude-code;
in
with pkgs; [
  (writeScriptBin "gemma-claude" ''
    #! /bin/sh
    exec env \
      ANTHROPIC_BASE_URL=http://yulee:8002 \
      ANTHROPIC_API_KEY=dummy \
      ANTHROPIC_DEFAULT_SONNET_MODEL=diffusiongemma \
      ANTHROPIC_DEFAULT_HAIKU_MODEL=diffusiongemma \
      ANTHROPIC_DEFAULT_OPUS_MODEL=gemma4-31b \
      CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000 \
      ${claude-code}/bin/claude "$@"
  '')
]

