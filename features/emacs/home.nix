{
  config,
  lib,
  pkgs,
  inputs,
  osConfig,
  ...
}:

let
  cfg = osConfig.my.emacs;

  emacsEnv = import ./env.nix { inherit pkgs inputs; };

  emacsPackage = if cfg.headless then emacsEnv.emacsNox else emacsEnv.emacsRolling;

  # Prebuilt tree-sitter grammar .so files (nixpkgs ships every language Doom
  # needs, typst included). Read via TREESIT_GRAMMAR_DIR below instead of
  # letting `treesit-auto`/`treesit-install-language-grammar` git-clone and
  # compile grammars at runtime -- there is no "just let Emacs download it"
  # under a Nix-managed profile.
  treesitGrammars = pkgs.emacsPackages.treesit-grammars.with-all-grammars;
in
lib.mkIf cfg.enable {
  # Doom owns Emacs startup; skipping this avoids an emacsWithPackages
  # wrapper injecting default.el on top of what programs.doom-emacs builds.
  programs.emacs.enable = false;

  programs.doom-emacs = {
    enable = true;
    doomDir = inputs.feat-emacs.doomDir;
    doomLocalDir = "${config.xdg.dataHome}/doom";
    emacs = emacsPackage;
    # Nix >2.18 breaks fetchGit's revision resolution for Unstraightened's
    # per-package fetches; fetchTree does not have that problem.
    experimentalFetchTree = true;
    extraBinPackages = with pkgs; [
      git
      ripgrep
      fd
      findutils
      gnutar
      gzip
      gcc # native-comp / org-babel C, not tree-sitter grammars (Nix-provided now).
      # Org export, ox-pandoc, and markdown-mode's markdown-command. In
      # extraBinPackages rather than home.packages so the DAEMON finds it: a
      # systemd user service does not inherit the login shell's PATH, which is
      # the same reason git/ripgrep/gcc are here.
      #
      # COST NOTE, because the obvious measurement is misleading. Adding this
      # currently costs 18 derivations, all Emacs re-wrapping and home-manager
      # glue, with pandoc-cli substituting prebuilt from cache.nixos.org. That
      # is not because pandoc is judged non-runtime -- it plainly is runtime --
      # but because nothing has told the classifier yet: Tier 1 is the live
      # system closure and pandoc is not installed, Tier 2's cache predates this
      # line, and Tier 3 anchors on features/*/packages.nix plus
      # my.packages.extra, neither of which sees extraBinPackages.
      #
      # extraBinPackages is wired through makeWrapper --prefix PATH, so pandoc's
      # store path ends up inside the wrapper script: a real runtime reference.
      # Once this is switched to and runtime-cache-refresh runs, Tier 1 picks it
      # up, isHostRuntime flips true, and the O3/LTO overlays claim it -- at
      # which point it is rebuilt from source and pulls a GHC toolchain.
      #
      # Left tuned rather than excluded: that is the classifier working as
      # designed. If the Haskell build is not worth it, the lever is buildOnly
      # in tuning/runtime-cache/lookup.nix, the same way ccache and cmake are
      # kept out -- GHC does not autovectorize, so the tuning buys close to
      # nothing here (see the nixfmt note in tuning/overlays/pseudo-cross.nix).
      pandoc
    ];
  };

  home.packages = [
    pkgs.imagemagick # PGTK Emacs cannot enable --with-imagemagick in nixpkgs; use CLI / scripts.
  ];

  # systemd user services (the Emacs daemon included) don't inherit
  # home.sessionVariables/hm-session-vars on this system -- see the
  # cursor-theme feature's XCURSOR_THEME for the same mechanism.
  systemd.user.sessionVariables = {
    TREESIT_GRAMMAR_DIR = "${treesitGrammars}/lib";
  };

  # Loaded by Doom's config.el when present; empty by default, so a host that
  # says nothing gets no file at all rather than an empty one.
  xdg.configFile."home-manager/doom-machine-local.el" =
    lib.mkIf (cfg.machineLocalElisp != "") { text = cfg.machineLocalElisp; };

  /*
    programs.doom-emacs wires services.emacs.package to its built emacsWithDoom
    automatically once provideEmacs is left at its default (true) -- this just
    needs to be turned on. home-manager's own unit (Type=notify,
    SuccessExitStatus=15, login-shell ExecStart) replaces the hand-rolled one
    this config used to define.
  */
  services.emacs = {
    enable = true;

    /*
      "graphical" binds the unit to graphical-session.target, which only ever
      gets started by a compositor. On a headless host there is none, so the
      daemon must hang off default.target instead or it would simply never
      start -- and it is reached with `emacsclient -nw` over ssh, where that is
      what you want anyway.
    */
    startWithUserSession = if cfg.headless then true else "graphical";
  };
}
