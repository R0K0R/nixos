{ config, lib, pkgs, ... }:

let
  cfg = config.my.zsh;

  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };

  # Preferences shared with features/zsh/home.nix -- see that file's header for
  # why they live apart from both halves.
  interactive = import ./interactive.nix;

  # Accounts whose LOGIN shell is zsh. Matched on pname rather than by
  # comparing derivations, so an overridden or wrapped zsh still counts.
  zshLoginUsers = lib.attrNames (
    lib.filterAttrs (_: u: u.shell != null && (u.shell.pname or u.shell.name or "") == "zsh") config.my.users
  );
in

{
  options.my.zsh.enable = lib.mkEnableOption "the zsh shell user config: aliases, completion, highlighting and interactive init";

  options.my.zsh.systemIntegration = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Turn on the NixOS `programs.zsh` module, i.e. zsh as a SYSTEM shell
      rather than only a home-manager program. The same reasoning as
      my.fish.systemIntegration applies, with one zsh-specific difference.

      NOT about /etc/shells: NixOS collects every declared login shell into that
      file on its own, so `my.users.<n>.shell = pkgs.zsh` is a valid login shell
      with or without this option.

      What is genuinely missing without it:

        * VENDOR COMPLETIONS. programs.zsh adds /share/zsh to
          environment.pathsToLink, which is what puts system packages'
          site-functions on fpath. Without it those completions sit unreferenced
          in their own store paths and compinit never sees them -- and it fails
          silently, reading as "zsh has no completion for this" rather than as a
          misconfiguration. This is the direct analogue of fish's vendor_* paths.

        * /etc/zshrc and /etc/zshenv, and the zsh package in systemPackages.

      ZSH-SPECIFIC: the NixOS module also owns compinit. programs.zsh.enableCompletion
      runs it system-wide, and home-manager's programs.zsh.enableCompletion runs
      it again per user. Running compinit twice is slow, not broken, so prefer
      leaving the home-manager one on (it is what this feature configures) and
      set programs.zsh.enableCompletion = false in the host if startup time
      matters.
    '';
  };

  options.my.zsh.systemPlugins = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Provide the plugins and keybinds through the NixOS `programs.zsh` module
      instead of home-manager: autosuggestions, syntax highlighting with the
      same fish-derived styles, ctrl+arrow word movement and prefix history
      search on up/down.

      The point is accounts that have NO home-manager generation -- root above
      all. home-manager cannot reach root here (`my.<feature>.users` is an enum
      over my.users, and root is deliberately not one), so without this a root
      zsh is bare: no autosuggestions, no highlighting, up/down walking the
      whole history and ctrl+arrow unbound.

      home-manager's own plugin switches are turned OFF while this is on, and
      that is not a style preference. /etc/zshrc is sourced before ~/.zshrc, so
      enabling both would source zsh-syntax-highlighting twice in one shell,
      which double-wraps its widgets. The keybinds are exempt -- bindkey and
      WORDCHARS are plain assignments, so applying them twice is harmless.
    '';
  };

  options.my.zsh.root = {
    enable = lib.mkEnableOption ''
      zsh as root's login shell.

      Separate from my.zsh.enable, which is the home-manager half and cannot
      apply to root. Pair it with my.zsh.systemPlugins or root gets a bare
      zsh -- the warning below says so if it is missing
    '';

    shareHistoryWith = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "r0k0r";
      description = ''
        Account whose ~/.zsh_history root also writes to, or null for root's
        own /root/.zsh_history.

        Convenient on a single-human machine, where `sudo -i` losing the
        history of what you just ran is pure friction. Safe to share: /etc/zshrc
        already sets HIST_FCNTL_LOCK, so two shells appending concurrently do
        not interleave badly, and SHARE_HISTORY means each picks the other up.

        Be deliberate about it though -- root's commands land in a file owned by
        and readable as that user. Only reasonable where the same person is both
        accounts, which is why it is opt-in and names the account rather than
        defaulting to the primary user.
      '';
    };
  };

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/zsh/home.nix gates on via osConfig.
  # Accounts this feature applies to; defaults to the primary user.
  options.my.zsh.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      my.packages.perUser = lib.genAttrs cfg.users (_: pkgSet.user);
    })

    /*
      mkIf rather than `programs.zsh.enable = cfg.systemIntegration`, because
      types.bool merges with mergeEqualOption: a host that also sets
      programs.zsh.enable directly would collide with a definition of `false`
      rather than being overridden by it. Only ever assert the true case.
    */
    (lib.mkIf cfg.systemIntegration {
      programs.zsh.enable = true;
    })

    (lib.mkIf cfg.systemPlugins {
      # systemIntegration is what turns programs.zsh on at all; assert it here
      # rather than silently emitting plugin config into a disabled module.
      my.zsh.systemIntegration = true;

      programs.zsh = {
        autosuggestions = {
          enable = true;
          highlightStyle = interactive.autosuggestHighlight;
        };
        syntaxHighlighting = {
          enable = true;
          styles = interactive.syntaxStyles;
        };
        shellAliases = interactive.aliases;
        interactiveShellInit = interactive.interactiveInit;
      };
    })

    (lib.mkIf cfg.root.enable {
      users.users.root.shell = pkgs.zsh;

      # histFile is system-wide, so pointing it at a user's file is what makes
      # root and that user share one history. Left alone when null: /etc/zshrc's
      # own HISTFILE=$HOME/.zsh_history then gives root /root/.zsh_history.
      programs.zsh.histFile = lib.mkIf (cfg.root.shareHistoryWith != null)
        "${config.users.users.${cfg.root.shareHistoryWith}.home}/.zsh_history";
    })

    {
      warnings = lib.optional (cfg.root.enable && !cfg.systemPlugins) ''
        root's login shell is zsh, but my.zsh.systemPlugins is false.

        root has no home-manager generation, so nothing configures that shell:
        no autosuggestions, no syntax highlighting, up/down walk the entire
        history instead of filtering on what is typed, and ctrl+arrow is
        unbound. Set my.zsh.systemPlugins = true; or accept a bare root shell.
      '';
    }

    /*
      A WARNING, not an assertion, for the same reason as fish's: a zsh login
      shell without systemIntegration still works, it is DEGRADED (no vendor
      completions from system packages), and the degradation is invisible from
      inside.
    */
    {
      warnings = lib.optional (zshLoginUsers != [ ] && !cfg.systemIntegration) ''
        ${lib.concatStringsSep ", " zshLoginUsers} ${
          if lib.length zshLoginUsers == 1 then "has" else "have"
        } zsh as a login shell, but my.zsh.systemIntegration is false.

        The account works, but zsh will not see completions shipped by system
        packages -- programs.zsh is what links /share/zsh into the system
        profile, putting their site-functions on fpath. Set
        my.zsh.systemIntegration = true; or, if that is deliberate, this
        warning is the only thing it costs.
      '';
    }
  ];
}
