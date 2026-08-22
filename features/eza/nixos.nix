{ config, lib, ... }:

{
  /*
    Its own feature rather than part of `base`, because it is not baseline:
    it was `homeManager.common` and only one host ever consumed that list.
    Folding it into base handed it to the headless builder, where eza is built
    rather than substituted -- and eza generates its man pages with pandoc, so
    that pulled a 500-derivation Haskell toolchain into a machine that has no
    use for either.
  */
  options.my.eza.enable = lib.mkEnableOption "eza, the ls replacement";

  # Accounts this feature applies to; defaults to the primary user.
  options.my.eza.users = import ../../lib/user-scope.nix { inherit lib config; };
}
