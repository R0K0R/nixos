{ config, pkgs, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.zsh.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "zsh"; };
  interactive = import ./interactive.nix;
  # Plugins come from /etc/zshrc when the NixOS half provides them; sourcing
  # zsh-syntax-highlighting from both files double-wraps its widgets.
  systemPlugins = osConfig.my.zsh.systemPlugins;
in
lib.mkIf (osConfig.my.zsh.enable && inScope) {
  programs.zsh = {
    enable = true;

    # fish has all three built in. In zsh they are separate plugins, and
    # leaving any of them off is what makes a ported config feel worse than
    # the fish original rather than merely different.
    autosuggestion.enable = !systemPlugins;
    syntaxHighlighting.enable = !systemPlugins;
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

    shellAliases = interactive.aliases;

    /*
      The fish theme, translated. This is a MAPPING, not a copy: fish colours
      its own parse tree, zsh-syntax-highlighting colours a different one, and
      several fish variables have no counterpart at all (fish_color_cancel,
      fish_color_end, fish_color_host, fish_color_search_match and the
      fish_pager_color_* family, which belong to fish's pager).

      Kept identical where the concept exists on both sides.
    */
    syntaxHighlighting.styles = interactive.syntaxStyles;
    autosuggestion.highlight = interactive.autosuggestHighlight;

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

${interactive.interactiveInit}
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
