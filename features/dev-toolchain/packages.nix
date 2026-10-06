# Language servers, compilers and debuggers -- the interactive development set.
# `user` (users.users.<n>.packages), not `system`: these belong to a person, not
# to the machine.
{ pkgs }:
{
  user = with pkgs; [
    cursor-cli
    /*
      git from the BUILD splice, deliberately -- this is the only way to get
      `git send-email` on a tuned host.

      pkgs/by-name/gi/git/package.nix gates it twice:

        perlSupport      ? stdenv.buildPlatform == stdenv.hostPlatform,
        sendEmailSupport ? perlSupport,

      and my.tuning.march exists precisely to make those platforms differ. So on
      any host with march set, plain `git` is built with perlSupport = false and
      git-send-email is simply never installed -- verified: the tuned git ships
      git-cvsimport and git-imap-send but no git-send-email. `gitFull` does not
      help either; all-packages.nix sets its sendEmailSupport to the same
      buildPlatform == hostPlatform test.

      pkgsBuildHost is the plain native set, where those platforms ARE equal, so
      perlSupport is on and send-email is built. It is also byte-identical to
      upstream, hence substitutable from cache.nixos.org rather than built. On an
      untuned host (my.tuning.enable = false) pkgsBuildHost == pkgs, so this is a
      no-op there.

      The cost is that git itself is no longer -march tuned, which is nothing
      next to losing the tool kernel patches are sent with.
    */
    pkgsBuildHost.git
    # gh is NOT here: features/base/home.nix enables programs.gh, which installs
    # it into home.packages on every host -- and, the point of going through the
    # module, writes the git credential helper against a store path the
    # generation keeps alive. Listing it here too would put a second, unmanaged
    # gh in users.users.<n>.packages, shadowing that one by PATH order.
    /*
      nixd with import-from-derivation OFF, for every editor. /.nixd.json points
      nixd at a full host eval, and with IFD allowed that lets
      nix-doom-emacs-unstraightened trigger a doom-intermediates build on file
      open (once measured at 226 minutes). The eval workers nixd spawns inherit
      the environment, so NIX_CONFIG reaches them. Lost: completion inside
      features/emacs only.
    */
    (symlinkJoin {
      name = "nixd-no-ifd-${nixd.version}";
      paths = [ nixd ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/nixd --set NIX_CONFIG "allow-import-from-derivation = false"
      '';
    })
    nixfmt
    statix
    deadnix
    tree
    python3

    zip
    unzip
    # ~/KSA is a git-annex repo (unlocked, filter.annex.process): without this
    # every `git add`/checkout there fails to start its filter.
    #
    # Minus bup. nixpkgs hands git-annex a list of runtime tools (bup, curl,
    # rsync, gnupg, ...) that its configure step probes for; bup only enables
    # the bup special remote, which nothing here uses, and on the tuned set it
    # was a build of its own blocking the rebuild. git-annex's configure treats
    # every one of these as optional, so without it the bup remote is simply
    # not built in.
    # buildTools too: on this IntraISACross set nixpkgs also hands configure
    # build-platform copies of the same tools (pr/git-annex-cross-configure-tools),
    # and bup would come back through that list.
    (haskell.lib.compose.overrideCabal (drv: {
      executableSystemDepends = builtins.filter (d: (d.pname or "") != "bup") (drv.executableSystemDepends or [ ]);
      buildTools = builtins.filter (d: (d.pname or "") != "bup") (drv.buildTools or [ ]);
    }) git-annex)

    # Python LSP for Emacs `lsp-pyright` when using BasedPyright (`basedpyright-langserver`).
    basedpyright
    clang-tools # clangd LSP + clang-format/clang-tidy
    gcc
    gdb
    tinymist
    typst
  ];

  system = with pkgs; [
    openjdk25_headless
  ];
}
