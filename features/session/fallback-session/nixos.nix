{ config, lib, pkgs, ... }:

let
  cfg = config.my.fallback-session;
  mkScript = config.my.epoch.internal.mkScript;
  inherit (config.my.epoch.internal.tools) hm-switch hm-rollback;

  /*
    Everything the fallback session runs comes from the SYSTEM package set
    and the system's own scripts: the point of the session is to work when
    the user's home does not, so nothing in it may come from that home.
    cage and kitty load the graphics driver -- the system's, which by
    construction matches the running epoch.
  */
  session-epoch-check = mkScript "session-epoch-check" [ ] (builtins.readFile ./session-epoch-check.sh);

  fallback-brief = mkScript "fallback-brief" [ session-epoch-check ] (builtins.readFile ./fallback-brief.sh);

  fallback-banner = mkScript "fallback-banner" (
    [
      session-epoch-check
      fallback-brief
      hm-switch
      hm-rollback
      pkgs.gnused
      pkgs.ncurses # clear
      pkgs.bashInteractive
    ]
    ++ lib.optional (cfg.claude != null) cfg.claude
  ) (builtins.readFile ./fallback-banner.sh);

  /*
    Under my.gl-namespace a mapped user's /run/opengl-driver is THEIR tree,
    possibly built against another system epoch -- the very case this session
    exists for. cage and kitty are the system's, so they get the system's
    tree through gl-system-driver. Only when the namespace is active, so the
    script is unchanged everywhere else.
  */
  glNs = config.my.gl-namespace.active or false;
  fallback-session = mkScript "fallback-session" ([ pkgs.cage pkgs.kitty fallback-banner ] ++ lib.optional glNs config.my.gl-namespace.systemDriverEnv) (
    lib.optionalString glNs ''
      cage() { gl-system-driver cage "$@"; }
    ''
    + lib.optionalString (cfg.normalSession != null) ''
      FALLBACK_DEFAULT_NORMAL=${lib.escapeShellArg cfg.normalSession}
    ''
    + builtins.readFile ./fallback-session.sh
  );

  guarded-session = mkScript "guarded-session" [ session-epoch-check fallback-session ] (
    ''
      GUARD_STRICT=${if cfg.unrecordedIsMismatch then "1" else "0"}
      GUARD_USERS=${lib.escapeShellArg (lib.concatStringsSep " " guardUsers)}
    ''
    + builtins.readFile ./guarded-session.sh
  );

  epoch-login-banner = mkScript "epoch-login-banner" [ pkgs.getent ] (builtins.readFile ./epoch-login-banner.sh);

  /*
    A wayland-sessions entry, so greetd's greeter (dms-greeter, tuigreet
    --sessions) lists it beside the compositor. Picking it by hand is always
    possible; being SENT to it is the guard's job. Never guarded itself
    (passthru.epochGuard = false): it is the place a mismatch is sent to.
  */
  sessionEntry =
    (pkgs.writeTextDir "share/wayland-sessions/fallback.desktop" ''
      [Desktop Entry]
      Name=Fallback (system terminal)
      Comment=Minimal system session: check and repair your home generation
      Exec=${fallback-session}/bin/fallback-session
      Type=Application
    '').overrideAttrs
      {
        passthru = {
          providedSessions = [ "fallback" ];
          epochGuard = false;
        };
      };

  /*
    THE GUARD: every session the greeter can offer, routed through
    guarded-session.

    WHERE IT HOOKS IN, AND WHY THERE. greetd (0.10) has no session wrapper of
    its own: it runs whatever command line the greeter sends, through
    `sh -c '. /etc/profile; . ~/.profile; exec "$@"'`. The greeter takes that
    command line from a .desktop file's Exec=, and every greeter here reads the
    same files -- dms-greeter scans XDG_DATA_DIRS/wayland-sessions, which on
    NixOS is services.displayManager.sessionData.desktops (the "desktops"
    aggregate of sessionPackages); tuigreet is pointed at a directory. So the
    one place that sees EVERY session, whoever added it, is that aggregate:
    this builds it again from the same sessionPackages with each entry's Exec=
    prefixed by guarded-session, under the SAME file name. The greeter's
    remembered choice (dms-greeter keeps the desktop id, hyprland.desktop) is
    therefore the guarded one from the first login on, with nothing to pick.

    "START ANYWAY" FROM THE GREETER: beside each guarded <id>.desktop a
    <id>-ignore-epoch.desktop, "<Name> (ignore epoch)", running
    `guarded-session --ignore-epoch` (logged, then the session). The fallback
    session's [s] is the other way to the same place.

    Same derivation name, "desktops": my.epoch.ignoreSurface drops it from the
    epoch BY NAME (it reaches XDG_DATA_DIRS), so turning the guard on does not
    move the epoch it is checking.

    Packages with passthru.epochGuard = false are linked through unchanged:
    the fallback entry above, and kiosk sessions (features/core/users/
    kiosk.nix), which run only system code. The upstream aggregate's sanity
    check (every providedSessions name has its file) is kept.
  */
  dm = config.services.displayManager;
  unguarded = p: !(p.epochGuard or true);
  guardedPkgs = lib.filter (p: !(unguarded p)) dm.sessionPackages;
  guardedDesktops =
    pkgs.runCommand "desktops"
      {
        # trivial derivation, as upstream's
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        mkdir -p "$out/share/"{xsessions,wayland-sessions}
        guard=${guarded-session}/bin/guarded-session

        # put KIND SRC: one entry, guarded or passed through. First one wins,
        # as with upstream's lndir.
        put() {
          local kind=$1 src=$2 mode=$3 id dst
          id=$(basename "$src" .desktop)
          dst=$out/share/$kind/$id.desktop
          [ -e "$dst" ] && return 0
          if [ "$mode" = plain ]; then
            ln -s "$src" "$dst"
            return 0
          fi
          grep -q '^Exec=' "$src" || { echo "$src has no Exec= line" >&2; return 1; }
          sed -e "s|^Exec=|Exec=$guard |" "$src" > "$dst"
          sed -e "s|^Exec=|Exec=$guard --ignore-epoch |" \
              -e 's|^Name=\(.*\)$|Name=\1 (ignore epoch)|' \
              "$src" > "$out/share/$kind/$id-ignore-epoch.desktop"
        }

        ${lib.concatMapStrings (pkg: ''
          for n in ${lib.concatStringsSep " " pkg.providedSessions}; do
            if ! test -f ${pkg}/share/wayland-sessions/$n.desktop -o \
                      -f ${pkg}/share/xsessions/$n.desktop; then
              echo "Couldn't find provided session name, $n.desktop, in session package ${pkg.name}:"
              echo "  ${pkg}"
              exit 1
            fi
          done
          for kind in xsessions wayland-sessions; do
            for f in ${pkg}/share/$kind/*.desktop; do
              [ -e "$f" ] || continue
              put $kind "$f" ${if unguarded pkg then "plain" else "guard"}
            done
          done
        '') dm.sessionPackages}
      '';
  guardedNames = lib.concatMap (p: p.providedSessions) guardedPkgs;

  # Accounts whose session is a home-manager home: the only ones with a
  # generation to compare. Everyone else passes the guard untouched.
  guardUsers = lib.attrNames (lib.filterAttrs (_: u: u.home) config.my.users);
in
{
  options.my.fallback-session = {
    enable = lib.mkEnableOption ''
      the fallback session: cage + the system's kitty with a menu that compares
      the user's home generation epoch with the system's and offers rollback,
      hm-switch --update, Claude Code, or the normal session anyway. Adds a
      "Fallback" greetd session and the session-epoch-check / guarded-session
      scripts; diverting logins into it is separate (guard.enable) and off'';

    claude = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = if config.my.claude-code.enable then config.my.claude-code.package else null;
      defaultText = lib.literalExpression "config.my.claude-code.package when my.claude-code.enable, else null";
      description = ''
        The claude-code offered as [c], started in the user's home repo with
        fallback-brief as its first message. The claude-code feature's own
        package by default, so it carries that feature's extraBinPackages. null
        hides the option.
      '';
    };

    normalSession = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "start-hyprland";
      description = ''
        Command [s] starts when the fallback session was picked from the
        greeter directly (from guarded-session it starts the session that was
        guarded). null: [s] is only offered when guarded.
      '';
    };

    guard.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Route EVERY greetd session through guarded-session: the
        services.displayManager.sessionData.desktops aggregate is rebuilt with
        each entry's Exec= prefixed (same file names, so the greeter's
        remembered session is the guarded one), plus a "<Name> (ignore epoch)"
        entry per session to start it anyway from the greeter. A home-manager
        account whose active home generation does not match the running
        system's epoch -- or that has no generation yet -- gets the fallback
        session instead. Other accounts (kiosk, system-default) pass through.
        See the comment at guardedDesktops for why the aggregate is the hook.
      '';
    };

    unrecordedIsMismatch = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether guarded-session treats a home generation WITHOUT an epoch file
        as a mismatch. Since my.epoch puts the epoch module into every home
        built for the host (home-manager.sharedModules, so integrated and
        homeLib homes alike), an unrecorded generation is one built before
        the epoch was turned on, or against an older system revision. Off
        while such generations are what users still run -- the first login
        after turning the epoch on would otherwise land in the fallback, whose
        [u] needs the new revision to be fetchable by the home repo; on once
        every account has switched a home built for the new revision.
      '';
    };

    internal.guardedSession = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = guarded-session;
      description = "guarded-session, for a greeter that keeps its own session entries (features/session/tuigreet).";
    };

    internal.sessionEntry = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = sessionEntry;
      description = "The fallback session's wayland-sessions entry (share/wayland-sessions/fallback.desktop).";
    };

    pamBanner.services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "login" "sshd" ];
      description = ''
        PAM services whose session stage runs epoch-login-banner (pam_exec,
        optional, stdout): a TTY or ssh login with a mismatched home gets a
        warning on the terminal. Never blocks the login. Empty by default.

        pam_exec.so comes from the same pam package as pam_unix, so this does
        not move the epoch.
      '';
    };
  };

  config = lib.mkMerge [
    {
      my.internal.features.fallback-session = {
        # The scripts read /run/current-system/epoch.json and the history,
        # which only the epoch feature writes.
        requires = [ "epoch" ];
        enabledBy = cfg.enable;
      };
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [
        session-epoch-check
        fallback-brief
        fallback-session
        guarded-session
        epoch-login-banner
      ];

      services.displayManager.sessionPackages = [ sessionEntry ];

      security.pam.services = lib.genAttrs cfg.pamBanner.services (s: {
        rules.session.epoch-banner = {
          # Relative to pam_unix, as pam.nix's own warning asks.
          order = config.security.pam.services.${s}.rules.session.unix.order + 50;
          control = "optional";
          modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
          args = [
            "stdout"
            "quiet"
            "${epoch-login-banner}/bin/epoch-login-banner"
          ];
        };
      });
    })

    (lib.mkIf (cfg.enable && cfg.guard.enable) {
      /*
        Replaces the aggregate nixpkgs' display-managers module builds from the
        same sessionPackages. sessionData has no type, so its definitions merge
        as attrsets with `//`, the LAST definition winning per key -- and
        definitions come in reverse module order, upstream's last (measured:
        without mkAfter, upstream's `desktops` won). mkAfter is ordering the
        module system applies to any option before merging, so this
        definition goes last and its `desktops` (and `sessionNames`, which
        gains the ignore-epoch ids) win, while `wrapper` (x11) and
        `autologinSession` stay upstream's. mkForce would drop those two. The
        assertion below is the backstop.
      */
      services.displayManager.sessionData = lib.mkAfter {
        desktops = guardedDesktops;
        # Guarded first: upstream's autologinSession falls back to the head
        # of this list, which must not become the fallback session.
        sessionNames =
          guardedNames
          ++ lib.concatMap (p: p.providedSessions) (lib.filter unguarded dm.sessionPackages)
          ++ map (n: "${n}-ignore-epoch") guardedNames;
      };
      assertions = [
        {
          assertion = dm.sessionData.desktops.drvPath == guardedDesktops.drvPath;
          message = "my.fallback-session.guard: services.displayManager.sessionData.desktops is not the guarded aggregate (definition order changed?); sessions would start unguarded.";
        }
        {
          assertion = config.services.greetd.enable;
          message = "my.fallback-session.guard is enforced by greetd's greeters; greetd is off.";
        }
      ];
    })
  ];
}
