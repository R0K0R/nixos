{ config, lib, ... }:

let
  cfg = config.my.emacs;
in
{
  options.my.emacs = {
    enable = lib.mkEnableOption "Doom Emacs, built as real Nix derivations by nix-doom-emacs-unstraightened";

    headless = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Build the terminal-only Emacs (emacs-nox) instead of the
        pgtk/webkit/xwidgets one, and bind the daemon to default.target rather
        than graphical-session.target.

        Set this on a host with no display manager and no compositor. The pgtk
        build would still *run* under `-nw`, but it drags GTK, WebKit 2.38 and
        xwidgets into the closure of a machine that can never display them --
        and on a machine that also serves as a builder, that closure is built,
        not just downloaded.

        This replaced a `hostName == "victus-15"` test: the thing that decides
        the build is the absence of a display, not the name of a particular
        machine, and a cloned headless host has to get this right without
        being renamed.
      '';
    };

    machineLocalElisp = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Elisp written to ~/.config/home-manager/doom-machine-local.el, which
        Doom's config.el loads if present. For genuinely per-machine settings --
        font sizes tuned to one display, and nothing that should follow the
        config to another host.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.headless) {
    /*
      `withNativeCompilation` flips emacs' `meta.broken` in this nixpkgs fork.
      Isolated by evaluating each flag on the host's pkgs:

        emacs-nox plain              broken = false
        emacs-nox +withTreeSitter    broken = false
        emacs-nox +withNativeComp    broken = TRUE

      The pgtk build gets the equivalent downgrade from tuning/pkgs-config.nix,
      which lists emacs-pgtk there for the same reason. A headless host does not
      import that file -- it is meteorlake-specific qtbase patching and
      yulee-sandbox test exclusions, none of which applies elsewhere -- so
      downgrade just the names this build needs.

      Three keys because the value is checked at each wrapping stage: the bare
      package, its pseudo-cross spliced form, and Unstraightened's emacsWithDoom
      around it (the last is what the eval error actually named).
    */
    nixpkgs.config.problems.handlers = {
      emacs-nox.broken = "warn";
      emacs-nox-x86_64-unknown-linux-gnu.broken = "warn";
      emacs-nox-x86_64-unknown-linux-gnu-with-doom.broken = "warn";
    };
  };
}
