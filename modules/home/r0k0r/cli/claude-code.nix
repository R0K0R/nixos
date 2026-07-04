{ pkgs, lib, ... }:

{
  home.activation.claudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    $DRY_RUN_CMD npm install -g @anthropic-ai/claude-code
  '';
}
