{
  description = "HOP (Open HWP) -- HWP/HWPX document editor, pinned from the upstream GitHub release";

  # No nixpkgs input: this flake owns a pin and nothing more, so there is no
  # second package set and no two-level `follows` to get wrong. Same shape as
  # features/claude-desktop/flake.nix -- see its header.
  inputs.hop-bin = {
    url = "file+https://github.com/golbin/hop/releases/download/v0.4.1/HOP-linux-x64.deb";
    flake = false;
  };

  outputs =
    { hop-bin, ... }:
    {
      src = hop-bin;
      /*
        The version is exported rather than repeated in package.nix, which takes
        it as an argument. claude-desktop hardcodes it in both places and relies
        on update.sh to rewrite them together; one source of truth means a
        bumped URL cannot silently disagree with a stale version attr.
      */
      version = "0.4.1";
    };
}
