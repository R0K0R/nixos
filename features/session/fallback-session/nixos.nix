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

  fallback-session = mkScript "fallback-session" [ pkgs.cage pkgs.kitty fallback-banner ] (
    lib.optionalString (cfg.normalSession != null) ''
      FALLBACK_DEFAULT_NORMAL=${lib.escapeShellArg cfg.normalSession}
    ''
    + builtins.readFile ./fallback-session.sh
  );

  guarded-session = mkScript "guarded-session" [ session-epoch-check fallback-session ] (
    ''
      GUARD_STRICT=${if cfg.unrecordedIsMismatch then "1" else "0"}
    ''
    + builtins.readFile ./guarded-session.sh
  );

  epoch-login-banner = mkScript "epoch-login-banner" [ pkgs.getent ] (builtins.readFile ./epoch-login-banner.sh);

  /*
    A wayland-sessions entry, so greetd's greeter (dms-greeter, tuigreet
    --sessions) lists it beside the compositor. Picking it by hand is always
    possible; being SENT to it is guardSessions' job.
  */
  sessionEntry =
    (pkgs.writeTextDir "share/wayland-sessions/fallback.desktop" ''
      [Desktop Entry]
      Name=Fallback (system terminal)
      Comment=Minimal system session: check and repair your home generation
      Exec=${fallback-session}/bin/fallback-session
      Type=Application
    '').overrideAttrs
      { passthru.providedSessions = [ "fallback" ]; };

  /*
    The guard, per session: a copy of the package's wayland-sessions entries
    with Exec= routed through guarded-session, offered as "<name>-guarded".
    Built from an explicit list rather than by rewriting every
    services.displayManager.sessionPackages entry, which would define that
    option in terms of itself.
  */
  guardedEntry =
    p:
    let
      names = p.providedSessions or (throw "my.fallback-session.guardSessions: ${p.name} has no providedSessions");
    in
    (pkgs.runCommand "${p.name}-guarded-session" { } ''
      mkdir -p $out/share/wayland-sessions
      for n in ${lib.escapeShellArgs names}; do
        sed -e 's|^Exec=|Exec=${guarded-session}/bin/guarded-session |' \
            -e 's|^Name=\(.*\)$|Name=\1 (epoch-guarded)|' \
            ${p}/share/wayland-sessions/$n.desktop > $out/share/wayland-sessions/$n-guarded.desktop
      done
    '').overrideAttrs
      { passthru.providedSessions = map (n: "${n}-guarded") names; };
in
{
  options.my.fallback-session = {
    enable = lib.mkEnableOption ''
      the fallback session: cage + the system's kitty with a menu that compares
      the user's home generation epoch with the system's and offers rollback,
      hm-switch --update, Claude Code, or the normal session anyway. Adds a
      "Fallback" greetd session and the session-epoch-check / guarded-session
      scripts; diverting logins into it is separate (guardSessions) and off'';

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

    guardSessions = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ config.programs.hyprland.package ]";
      description = ''
        Session packages (with passthru.providedSessions) to offer an
        "epoch-guarded" variant of: the same entry with Exec= wrapped in
        guarded-session, which starts the session when the home generation
        matches the system epoch and the fallback session otherwise.

        Empty by default, so nothing is diverted. Making the guarded entry the
        DEFAULT the greeter picks is the greeter's setting and is left to the
        host.
      '';
    };

    unrecordedIsMismatch = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether guarded-session treats a home generation WITHOUT an epoch file
        as a mismatch. Off while homes are still built by the integrated
        home-manager (those always match the system they came with, and do not
        carry homeLib.<host>.epochModule); on once every home is standalone.
      '';
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

      services.displayManager.sessionPackages = [ sessionEntry ] ++ map guardedEntry cfg.guardSessions;

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
  ];
}
