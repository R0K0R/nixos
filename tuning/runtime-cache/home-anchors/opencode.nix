{ pkgs }:
{
  system = with pkgs; [
    opencode
    opencode-claude-auth
  ];
}
