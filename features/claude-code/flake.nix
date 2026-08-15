{
  description = "claude-code, pinned to an exact release from Anthropic's channel";

  /*
    No nixpkgs input at all. This flake exists only to own the pin, so there is
    nothing to `follows` and no second nixpkgs node to collide in the parent
    lock -- the `nixpkgs_2` rename that already bit this repo once, via
    nix-doom-emacs-unstraightened's own registry-fallback nixpkgs input, which
    silently renamed the fork and broke the runtime-cache scripts' jq lookups.

    The channel has no version-less "latest" URL, so the version lives in this
    URL and in the package's version attr. Bump both with ./update.sh.
  */
  inputs.claude-code-bin = {
    url = "file+https://downloads.claude.ai/claude-code-releases/2.1.223/linux-x64/claude";
    flake = false;
  };

  outputs =
    { claude-code-bin, ... }:
    {
      src = claude-code-bin;
      version = "2.1.223";
    };
}
