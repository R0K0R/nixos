{ pkgs, ... }:

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

