{
  description = "Claude Desktop (official Linux beta), pinned from Anthropic's apt repo";

  # No nixpkgs input: this flake owns a pin, nothing more. See
  # features/claude-code/flake.nix for why that matters.
  inputs.claude-desktop-bin = {
    url = "file+https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_1.24012.11_amd64.deb";
    flake = false;
  };

  outputs =
    { claude-desktop-bin, ... }:
    {
      src = claude-desktop-bin;
      version = "1.24012.11";
    };
}
