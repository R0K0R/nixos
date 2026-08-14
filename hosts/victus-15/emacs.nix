{ ... }:

{
  /*
    `withNativeCompilation` flips emacs' `meta.broken` in this nixpkgs fork.
    Isolated by evaluating each flag on this host's pkgs:

      emacs-nox plain              broken = false
      emacs-nox +withTreeSitter    broken = false
      emacs-nox +withNativeComp    broken = TRUE

    galaxybook4-pro360 gets the equivalent downgrade from
    modules/nixos/nix/pkgs-config.nix (which lists emacs-pgtk there for the same
    reason). victus-15 deliberately does NOT import that file: it is 300 lines of
    meteorlake-specific qtbase patching and yulee-sandbox test exclusions, none of
    which applies to a znver3 box. So downgrade just the names this host needs.

    Three keys because the value is checked at each wrapping stage: the bare
    package, its pseudo-cross spliced form, and Unstraightened's emacsWithDoom
    around it (the last is what the eval error actually named).
  */
  nixpkgs.config.problems.handlers = {
    emacs-nox.broken = "warn";
    emacs-nox-x86_64-unknown-linux-gnu.broken = "warn";
    emacs-nox-x86_64-unknown-linux-gnu-with-doom.broken = "warn";
  };
}
