{
  config,
  lib,
  pkgs,
  inputs,
  osConfig,
  ...
}:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.emacs.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "emacs"; };
in
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
lib.mkIf (cfg.enable && inScope) {
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

    /*
      typst-ts-mode's generated autoloads are not loadable under Emacs 31, and
      that one package takes the whole daemon down.

      SYMPTOM. emacs.service exits 255 at startup with

        Symbol's function definition is void: define-compilation-mode
        Symbol's function definition is void: vi-tilde-fringe-mode

      The second is a red herring. The first aborts Doom's
      `doom--startup-loaddefs-packages' loop, so every package whose autoloads
      had not been reached yet stays undefined, and the next hook to call one
      of them kills the daemon. Exactly one package is at fault -- confirmed by
      walking the generated init.<version>.el and checking every head symbol
      used inside a `(let* ((load-file-name ...)) ...)' autoloads block against
      fboundp, which finds define-compilation-mode and nothing else.

      Note `--batch' does NOT reproduce this: it skips the UI package loading
      that reaches the failing hook, so the same binary that dies as a daemon
      boots clean under `emacs --batch'. Reproduce with `--fg-daemon'.

      CAUSE. typst-ts-compile.el:108 puts a `;;;###autoload' cookie on a
      `define-compilation-mode' form -- a macro that lives in compile.el.
      Emacs 30's loaddefs-generate MACROEXPANDED that to a plain stub:

        (autoload 'typst-ts-compilation-mode "typst-ts-compile" "...")

      Emacs 31's copies the macro call in VERBATIM:

        (define-compilation-mode typst-ts-compilation-mode "Typst Compilation"
        "..." (setq-local compilation-error-regexp-alist-alist nil) ...)

      compile.el is not loaded when an autoloads file is, so evaluating that
      raises void-function. Same package version (0.12.2) both ways -- the
      difference is entirely which Emacs generated the autoloads, which is why
      this appeared the moment `emacs30: remove' forced 30.2 -> 31.1.

      WHY HERE AND NOT nixpkgs.overlays. Overriding `emacsPackagesFor' in a
      nixpkgs overlay looks like it works -- pkgs.emacs-pgtk.pkgs.typst-ts-mode
      really does pick up the change -- and is SILENTLY INEFFECTIVE, because
      Unstraightened does not use nixpkgs' emacsPackagesFor at all. Its
      flake.nix:71 takes emacs-overlay's instead:

        inherit (emacs-overlay.overlays.package { } pkgs) emacsPackagesFor;

      so the doom derivation's out path does not change. emacsPackageOverrides
      is the supported hook, applied after Doom's pins (default.nix:132).

      FIX. Make the macro reachable by autoload before the form is evaluated,
      inserted AFTER line 1 so the `-*- lexical-binding: t -*-' cookie stays on
      the first line -- prepending above it would silently switch the whole
      autoloads file to dynamic binding.

      Written to FAIL THE BUILD once it stops being needed rather than rot in
      place: if the raw macro form is gone from the generated autoloads, the
      guard aborts and says to delete this. Guarded with optionalAttrs so that
      dropping `(typst +lsp)' from init.el simply makes it a no-op instead of
      an eval error.
    */
    emacsPackageOverrides =
      _eself: esuper:
      lib.optionalAttrs (esuper ? typst-ts-mode) {
        typst-ts-mode = esuper.typst-ts-mode.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            autoloads="$(find "$out/share/emacs" -name typst-ts-mode-autoloads.el -print -quit)"

            if [ -z "$autoloads" ]; then
              echo "typst-ts-mode: no typst-ts-mode-autoloads.el under $out/share/emacs;" >&2
              echo "  the autoloads workaround in features/emacs/home.nix cannot apply." >&2
              exit 1
            fi

            if ! grep -q '^(define-compilation-mode typst-ts-compilation-mode' "$autoloads"; then
              echo "typst-ts-mode: the raw (define-compilation-mode ...) form is no longer in" >&2
              echo "  the generated autoloads, so this workaround is obsolete." >&2
              echo "  DELETE emacsPackageOverrides in features/emacs/home.nix." >&2
              exit 1
            fi

            if ! head -1 "$autoloads" | grep -q 'lexical-binding: t'; then
              echo "typst-ts-mode: line 1 of the autoloads is not the lexical-binding header;" >&2
              echo "  refusing to insert after it, which would change the binding mode." >&2
              exit 1
            fi

            shim="$(mktemp)"
            cat > "$shim" <<'SHIM'
            ;; Inserted by features/emacs/home.nix. Emacs 31's loaddefs-generate
            ;; copies the cookied (define-compilation-mode ...) form below verbatim
            ;; instead of expanding it to an autoload, and compile.el is not loaded
            ;; when this file is. Make the macro reachable rather than eagerly
            ;; requiring compile.
            (autoload 'define-compilation-mode "compile" nil nil 'macro)
            SHIM
            sed -i "1r $shim" "$autoloads"
            rm -f "$shim"
          '';
        });
      };
    extraBinPackages = with pkgs; [
      git
      ripgrep
      fd
      findutils
      gnutar
      gzip
      gcc # native-comp / org-babel C, not tree-sitter grammars (Nix-provided now).
      # epa/epg call `gpg` by name, and Gnus reaches them through auth-source
      # for the encrypted authinfo (see doom config's auth-sources). Both go
      # here rather than home.packages for the usual daemon-PATH reason
      # documented below -- with gpg absent, `epg-find-configuration` returns
      # nil and the authinfo lookup fails SILENTLY, indistinguishable from a
      # missing file.
      gnupg
      # gpg-agent needs a pinentry to prompt for the passphrase; without one
      # it aborts with "problem with the agent: No pinentry". The emacs
      # flavour draws the prompt inside Emacs itself -- no stray GTK window
      # to lose behind a Hyprland workspace, and it works over TRAMP/ssh
      # where a graphical pinentry cannot. Needs
      # `pinentry-program .../bin/pinentry-emacs` in ~/.gnupg/gpg-agent.conf
      # (or epa-pinentry-mode 'loopback) to actually be selected.
      pinentry-emacs
      # Doom's `:tools direnv` module shells out to the `direnv` binary
      # (`direnv export json`) on every buffer visit under a directory with an
      # .envrc. Here for the same daemon-PATH reason as everything else in this
      # list: home-manager's programs.direnv puts direnv in the user PROFILE and
      # hooks the interactive shells, but the Emacs daemon is a systemd user
      # service and inherits neither.
      #
      # Without it the module degrades quietly rather than erroring -- Emacs
      # simply never picks up a project's devShell, so compilation and LSP run
      # against the ambient environment and fail in ways that look like the
      # project's fault. features/direnv owns the switch; this is its Emacs
      # half, and the two are deliberately not cross-asserted (Emacs works
      # without direnv, and direnv works without Emacs).
      direnv
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
      # extraBinPackages is wired through makeWrapper `--suffix PATH` (see
      # build-helpers/build-doom-emacs.sh in Unstraightened), so pandoc's store
      # path ends up inside the wrapper script: a real runtime reference, and
      # the daemon finds it too. Once this is switched to and
      # runtime-cache-refresh runs, Tier 1 picks it up, isHostRuntime flips
      # true, and the O3/LTO overlays claim it -- at which point it is rebuilt
      # from source and pulls a GHC toolchain.
      #
      # DELIBERATELY LEFT TUNED. Adding it to buildOnly in
      # tuning/runtime-cache/lookup.nix would keep the prebuilt upstream binary
      # and skip the Haskell build, and there is a real argument for it (GHC
      # does not autovectorize -- see the nixfmt note in
      # tuning/overlays/pseudo-cross.nix). Rejected anyway: buildOnly means
      # "this never runs on the host", and pandoc does. Putting a genuine
      # runtime package there to dodge a build cost would make that list mean
      # two different things, and the next person reading it could not tell
      # which entries are claims about behaviour and which are cost dodges.
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

  /*
    gpg-agent, wired to the Emacs pinentry.

    Putting pinentry-emacs on PATH is NOT enough on its own: gpg-agent
    resolves its pinentry from a compiled-in default path, never from PATH,
    so without this it still aborts with

      gpg: problem with the agent: No pinentry

    which is what a bare `nix-shell -p gnupg` hits. This option writes
    `pinentry-program` into gpg-agent.conf, which is the part that actually
    selects it.

    Enabled alongside Emacs rather than as its own feature because that is
    what consumes it here -- Gnus reading the encrypted authinfo through
    auth-source (see the doom config's auth-sources). Anything else wanting
    gpg gets it for free, which is fine; if a headless host ever needs a
    different flavour, `pinentry.package` is the one knob to change.
  */
  services.gpg-agent = {
    enable = true;
    pinentry.package = pkgs.pinentry-emacs;
  };
}
