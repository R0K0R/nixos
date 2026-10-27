{ config, lib, ... }:

{
  options.my.fishTools.enable = lib.mkEnableOption ''
    zoxide and fzf with their fish hooks. Layered on the fish feature
    (features/shell/fish, which owns programs.fish); the fastfetch greeting is
    modules/shell/fastfetch
  '';

  config = lib.mkIf config.my.fishTools.enable {
    /*
      zoxide and fzf earn their keep only through the shell hooks, so they are
      declared here (with fish integration) rather than as bare binaries in a
      package list. zoxide adds `z <dir>` frecency jumping; fzf adds Ctrl-R
      history search and Ctrl-T file insertion. Both append their init to
      interactiveShellInit, which composes with the system feature's own block.
    */
    programs.zoxide = {
      enable = true;
      enableFishIntegration = true;
    };
    programs.fzf = {
      enable = true;
      enableFishIntegration = true;
    };
  };
}
