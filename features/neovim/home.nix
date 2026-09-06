{ config, lib, pkgs, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "neovim"; };
  cfg = osConfig.my.neovim;
  enabled = cfg.enable && inScope;

  /*
    NvChad's starter, pinned. There is no nvchad package in nixpkgs, and that
    is the correct state of the world: NvChad is a CONFIG, whose plugin set
    lazy.nvim manages imperatively inside the config directory (lazy-lock.json,
    plugin clones under ~/.local/share/nvim). A store-symlinked ~/.config/nvim
    breaks that on first sync.
  */
  starter = pkgs.fetchFromGitHub {
    owner = "NvChad";
    repo = "starter";
    rev = "e3572e1f5e1c297212c3deeb17b7863139ce663e";
    hash = "sha256-xdLr6tlU9uA+wu0pqha2br0fdVm+1MjgjbB5awz9ICU=";
  };
in
lib.mkIf enabled {
  home.packages = [
    pkgs.neovim
    # lazy.nvim clones plugins over git at first launch; treesitter compiles
    # grammars with a C compiler; telescope wants ripgrep. git and gcc are
    # already on this host (base / dev-toolchain), rg rides along here so the
    # feature stands alone.
    pkgs.ripgrep
  ];

  /*
    SEEDED, not linked -- the same contract as hakuspace's control dir, for
    the same reason: this is the user's editor config. NvChad's own docs say
    "clone and make it yours"; every keymap the user adds lands in these
    files, and lazy.nvim writes lazy-lock.json next to them. Existing files
    are never touched, so the seed happens exactly once and updates to the
    pinned rev deliberately do NOT propagate -- by then the config is theirs.
  */
  home.activation.nvchadSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -e "$HOME/.config/nvim" ]; then
      run mkdir -p "$HOME/.config"
      run cp -r ${starter} "$HOME/.config/nvim"
      run chmod -R u+w "$HOME/.config/nvim"
      run rm -rf "$HOME/.config/nvim/.git"
    fi
  '';

  /*
    Named `nvim`, deliberately: XDG gives ~/.local/share/applications
    precedence over the profile's share/applications, so this SHADOWS the
    Terminal=true nvim.desktop the neovim package ships -- one launcher
    entry, not two, and it opens in kitty instead of depending on whatever
    a menu decides a "terminal" is.
  */
  xdg.desktopEntries.nvim = {
    name = "Neovim";
    genericName = "Text Editor";
    exec = "kitty -e nvim %F";
    terminal = false;
    icon = "nvim";
    categories = [
      "Utility"
      "TextEditor"
      "Development"
    ];
    mimeType = [
      "text/plain"
      "text/x-makefile"
      "text/x-c"
      "text/x-python"
    ];
  };
}
