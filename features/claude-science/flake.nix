{
  description = "Claude Science (beta), pinned from Anthropic's downloads";

  # No nixpkgs input: this flake owns a pin, nothing more. Same shape as
  # ../claude-desktop -- see ../claude-code/flake.nix for why that matters.
  #
  # The advertised link is .../latest/linux-x64, which is a moving target and
  # unusable as a pin. The versioned path serves the same bytes and is what
  # ./update.sh rewrites.
  inputs.claude-science-bin = {
    url = "file+https://downloads.claude.ai/claude-science/0.1.50/linux-x64";
    flake = false;
  };

  outputs =
    { claude-science-bin, ... }:
    {
      src = claude-science-bin;
      version = "0.1.50";
    };
}
