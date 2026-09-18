{ config, pkgs, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.zsh.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "zsh"; };
in
lib.mkIf (osConfig.my.zsh.enable && inScope) {
  programs.zsh = {
    enable = true;

    # fish has all three built in. In zsh they are separate plugins, and
    # leaving any of them off is what makes a ported config feel worse than
    # the fish original rather than merely different.
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    enableCompletion = true;

    # fish_default_key_bindings.
    defaultKeymap = "emacs";

    /*
      fish keeps history per session with automatic dedup and shares it
      between running shells. zsh does none of that by default -- these
      options are what buy the fish behaviour, not embellishment.
    */
    history = {
      size = 100000;
      save = 100000;
      share = true;
      ignoreDups = true;
      ignoreSpace = true;
      expireDuplicatesFirst = true;
      extended = true;
    };

    shellAliases = {
      # Kitty doesn’t clear properly; hard-reset scrollback + cursor.
      clear = "printf '\\033[2J\\033[3J\\033[1;1H'";
      celar = "printf '\\033[2J\\033[3J\\033[1;1H'";
      claer = "printf '\\033[2J\\033[3J\\033[1;1H'";
      pamcan = "pacman";
      q = "qs -c ii";
    };

    /*
      The fish theme, translated. This is a MAPPING, not a copy: fish colours
      its own parse tree, zsh-syntax-highlighting colours a different one, and
      several fish variables have no counterpart at all (fish_color_cancel,
      fish_color_end, fish_color_host, fish_color_search_match and the
      fish_pager_color_* family, which belong to fish's pager).

      Kept identical where the concept exists on both sides.
    */
    syntaxHighlighting.styles = {
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
    autosuggestion.highlight = "fg=#555555";

    initContent = ''
      if [ -f ~/.local/state/quickshell/user/generated/terminal/sequences.txt ]; then
        cat ~/.local/state/quickshell/user/generated/terminal/sequences.txt
      fi

      if [ "$TERM" != linux ]; then
        alias ls='eza --icons'
      fi
      if [ "$TERM" = xterm-kitty ]; then
        alias ssh='kitten ssh'
      fi

      # Ctrl+left / Ctrl+right word movement, and prefix history search on
      # up/down. Both are fish defaults that this port silently dropped: zsh
      # leaves Ctrl+arrow as `undefined-key` and binds the arrows to
      # up-line-or-history, a flat walk through every command ever run.

      # The sequences are spelled out rather than taken from terminfo because
      # terminfo does not carry them: xterm-kitty's kLFT/kRIT are \E[1;2D/C,
      # which is SHIFT+arrow (CSI modifier 2), and there is no ctrl entry at
      # all. Ctrl is modifier 5, hence 1;5D / 1;5C. The 1;3 pair is the same
      # chord under Alt on terminals that send it, \EOd/\EOc is the urxvt
      # spelling and \E[5D/C the older xterm one -- all harmless if a given
      # terminal never emits them.
      bindkey '^[[1;5D' backward-word
      bindkey '^[[1;5C' forward-word
      bindkey '^[[1;3D' backward-word
      bindkey '^[[1;3C' forward-word
      bindkey '^[Od'    backward-word
      bindkey '^[Oc'    forward-word
      bindkey '^[[5D'   backward-word
      bindkey '^[[5C'   forward-word

      # up-line-or-beginning-search, NOT history-beginning-search-backward:
      # the plain widget would break editing a multi-line command, because up
      # would jump to another history entry instead of moving a line up. This
      # one moves within the buffer when it is multi-line and only
      # prefix-searches on a single line, which is what fish does. It also
      # restores the cursor column across repeated presses.

      # Both the normal (\E[A) and application-mode (\EOA) spellings are
      # bound -- the terminal switches to the latter whenever something calls
      # smkx, and a binding on only one form works until it silently does not.
      autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
      zle -N up-line-or-beginning-search
      zle -N down-line-or-beginning-search
      bindkey '^[[A' up-line-or-beginning-search
      bindkey '^[[B' down-line-or-beginning-search
      bindkey '^[OA' up-line-or-beginning-search
      bindkey '^[OB' down-line-or-beginning-search

      # Word boundaries, so the movement above lands where fish lands. zsh's
      # default WORDCHARS keeps / - . = inside a word, which makes Ctrl+left
      # swallow a whole path in one hop. Dropping them splits on path
      # components and hyphens the way fish does.
      WORDCHARS='*?_[]~&;!#$%^(){}<>'

      # NO TRANSIENT PROMPT. features/fish sets
      # functions.starship_transient_prompt_func and calls enable_transience,
      # both of which are FISH-ONLY in starship: `starship init zsh
      # --print-full-init` on 1.26.0 emits no transience machinery at all
      # (verified 2026-09-13), so there is nothing to call. Reproducing it
      # would mean hand-rolling a zle-line-finish hook that redraws PROMPT,
      # which is a behaviour change dressed as a port -- left out
      # deliberately rather than silently.
      if [ "$TERM" != linux ]; then
        eval "$(${pkgs.starship}/bin/starship init zsh)"
      fi
    '';
  };
}
