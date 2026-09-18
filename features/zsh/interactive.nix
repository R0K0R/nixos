/*
  The interactive-zsh config that BOTH halves need, in one place.

  features/zsh/home.nix configures zsh for a home-manager account;
  features/zsh/nixos.nix configures it system-wide for accounts that have no
  home-manager generation -- root above all. Those are two delivery mechanisms
  for one set of preferences, and keeping the preferences here means the two
  cannot drift into "root's shell highlights differently from mine".

  Values only. Neither half is named here, and nothing in this file knows which
  one is consuming it.
*/
{
  # Ported from fish_color_*; the trailing comments name the fish variable each
  # one came from, so a future retune has something to compare against.
  syntaxStyles = {
    command = "fg=blue";
    builtin = "fg=blue";
    function = "fg=blue";
    alias = "fg=blue";
    precommand = "fg=blue";
    comment = "fg=red";
    unknown-token = "fg=red,bold"; # fish_color_error brred
    single-quoted-argument = "fg=yellow"; # fish_color_quote
    double-quoted-argument = "fg=yellow";
    dollar-double-quoted-argument = "fg=brcyan"; # fish_color_escape
    back-double-quoted-argument = "fg=brcyan";
    redirection = "fg=cyan,bold"; # fish_color_redirection
    commandseparator = "fg=brcyan"; # fish_color_operator
    path = "underline"; # fish_color_valid_path
    default = "fg=cyan"; # fish_color_param
  };

  # fish_color_autosuggestion '555 brblack'.
  autosuggestHighlight = "fg=#555555";

  aliases = {
    # Kitty doesn't clear properly; hard-reset scrollback + cursor.
    clear = "printf '\\033[2J\\033[3J\\033[1;1H'";
    celar = "printf '\\033[2J\\033[3J\\033[1;1H'";
    claer = "printf '\\033[2J\\033[3J\\033[1;1H'";
    pamcan = "pacman";
    q = "qs -c ii";
  };

  # Key bindings and word boundaries.
  #
  # COMMENTS INSIDE THE STRING BELOW MUST BE SHELL COMMENTS. Nix passes a block
  # comment through verbatim, zsh then reads the opening slash-star as a glob
  # and every line of prose as a command. That has been hit twice in this
  # feature -- and once more in this very file, because writing the closing
  # delimiter inside a Nix block comment ends it early. It survives
  # `nix-instantiate --parse`; it only shows up when the generated rc is
  # sourced and stderr is read.
  #
  # Safe to apply twice: bindkey and WORDCHARS are assignments, so an account
  # that gets this from both /etc/zshrc and its own rc is not harmed.
  interactiveInit = ''
    # Ctrl+left / Ctrl+right word movement. Spelled out rather than taken from
    # terminfo, which does not carry them: xterm-kitty's kLFT/kRIT are
    # \E[1;2D/C -- SHIFT+arrow, CSI modifier 2 -- and there is no ctrl entry.
    # Ctrl is modifier 5, hence 1;5D/1;5C. The rest are the same chord as other
    # terminals spell it, and are inert where they are never emitted.
    bindkey '^[[1;5D' backward-word
    bindkey '^[[1;5C' forward-word
    bindkey '^[[1;3D' backward-word
    bindkey '^[[1;3C' forward-word
    bindkey '^[Od'    backward-word
    bindkey '^[Oc'    forward-word
    bindkey '^[[5D'   backward-word
    bindkey '^[[5C'   forward-word

    # Prefix history search on up/down, which is what fish does. Plain zsh
    # binds these to up-line-or-history, a flat walk through every command ever
    # run that ignores whatever is already typed.
    #
    # up-line-or-beginning-search, NOT history-beginning-search-backward: the
    # plain widget breaks editing a multi-line command, because up would jump
    # to another history entry instead of moving a line within the buffer.
    # Both the normal (\E[A) and application-mode (\EOA) spellings are bound --
    # the terminal switches to the latter whenever something calls smkx.
    autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
    zle -N up-line-or-beginning-search
    zle -N down-line-or-beginning-search
    bindkey '^[[A' up-line-or-beginning-search
    bindkey '^[[B' down-line-or-beginning-search
    bindkey '^[OA' up-line-or-beginning-search
    bindkey '^[OB' down-line-or-beginning-search

    # zsh's default WORDCHARS keeps / - . = inside a word, so ctrl+left would
    # swallow a whole path in one hop. Dropping them splits on path components
    # and hyphens, where fish lands.
    WORDCHARS='*?_[]~&;!#$%^(){}<>'
  '';
}
