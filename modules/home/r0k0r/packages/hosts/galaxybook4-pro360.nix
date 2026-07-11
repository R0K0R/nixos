{ pkgs, inputs, ... }:

let
  # Same pinned claude-code as modules/nixos/packages/common.nix (vendored
  # package; binary hash-pinned via the claude-code-bin flake input).
  claude-code = pkgs.callPackage ../../../../nixos/packages/claude-code/package.nix {
    src = inputs.claude-code-bin;
  };
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

