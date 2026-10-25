/*
  GNOME, scoped to its own sessions: the desktop behind the registry's
  session = { desktop = "gnome"; } (guest and handoff on galaxybook4-pro360),
  also offered in the greeter as "GNOME" to anyone. Everyone else's sessions
  must not notice that it is installed.

  WHY NOT services.desktopManager.gnome. The nixpkgs module is written for a
  machine whose desktop IS GNOME, and most of what it does is system-wide.
  Audited against this nixpkgs (gnome.nix + services/desktops/gnome/*), what
  it would have changed for a Hyprland user on the same machine:

    environment   sessionPath = [ gnome-shell ] -> extraInit exports
                  XDG_DATA_DIRS, GI_TYPELIB_PATH and LD_LIBRARY_PATH (gnome-
                  shell's lib) in every login shell; NIX_GSETTINGS_OVERRIDES_DIR,
                  NAUTILUS_4_EXTENSION_DIR, a mimeapps XDG_DATA_DIRS entry;
                  glib-networking and gvfs add GIO_EXTRA_MODULES; at-spi2-core
                  (forced on) drops NO_AT_BRIDGE / GTK_A11Y=none. All of these
                  are on the epoch surface (lib/epoch.nix: env) -- the epoch
                  would move and the guard would send r0k0r and benjamin to
                  the fallback session until they rebuilt their homes.
    /run/current-system/sw
                  pathsToLink "/share" (cannot be taken back out of a list
                  option) links every system package's whole share/, and
                  environment.systemPackages gains gnome-shell, gnome-settings-
                  daemon, glib (whose schemas system-path then compiles), the
                  apps: their .desktop files in every launcher, their D-Bus
                  services activatable on every session bus (gnome-shell ships
                  org.gnome.ScreenSaver, Nautilus org.freedesktop.FileManager1:
                  "show in folder" would open Nautilus under Hyprland), their
                  etc/xdg/autostart entries.
    autostart / user units
                  xdg-user-dirs(-gtk) (creates ~/Desktop etc. at every login),
                  localsearch/tinysparql indexers, gcr-ssh-agent (an
                  SSH_AUTH_SOCK for everyone), evolution-data-server (forced).
    PAM           gnome-keyring adds pam_gnome_keyring to login/greetd/passwd:
                  on the epoch surface (pam).
    services      udisks2 (forced), rtkit (pipewire would go realtime for
                  everyone), pkexec setuid wrapper, bolt, colord, avahi, rygel,
                  gnome-remote-desktop, gnome-user-share, initial-setup,
                  orca, system-config-printer, dleyna; geoclue2.enableDemoAgent
                  forced FALSE (gb4's Hyprland session uses the demo agent).
    fonts         adwaita-fonts in fonts.packages (fontconfig for everyone).
    input method  i18n.inputMethod.type mkDefault "ibus" (gb4 sets fcitx5).
    portals       x-d-p-gnome in extraPortals, gnome-session's portals.conf.

  Most of it is mkDefault and could be switched back off; five pieces cannot
  be removed from outside (pathsToLink, the forced systemPackages, the
  forced services) and the rest would be a list of overrides to re-audit at
  every nixpkgs bump. So this feature assembles the session itself.

  WHAT IS SYSTEM-WIDE HERE, all of it inert outside a GNOME session:

    systemd.packages   gnome-session, gnome-shell, gnome-settings-daemon,
                       xdg-desktop-portal-gnome: user units with no [Install]
                       section (checked on the 50.x units), started only by
                       gnome-session's own targets or by D-Bus activation
                       from inside the session. Plus the two x11-services
                       target wants nixpkgs' g-s-d module adds and its
                       gnome-session-monitor drop-in.
    the greeter entry  share/wayland-sessions/gnome.desktop (Exec = the
                       launcher below), guarded by the fallback session like
                       any other entry; appended last so the compositor's
                       entries stay first (the head of sessionNames is
                       displayManager's autologin default).
    session pins       /etc/profile's pin lines (session-pin.nix) for the
                       accounts whose registry session is { desktop = "gnome"; }.

  WHAT IS IN THE LAUNCHER, i.e. only in a GNOME session's environment (and
  from there in that user's systemd manager, which gnome-session uploads it
  to): XDG_CURRENT_DESKTOP / XDG_SESSION_DESKTOP / XDG_SESSION_TYPE, the
  session's data dirs (the packages' share/ and their gsettings-schemas
  dirs, as nixpkgs' extraInit would build them), XDG_CONFIG_DIRS, PATH, the
  gsettings overrides (lock screen off, favourites, background), a
  fontconfig file that adds Adwaita Sans/Mono,
  and the session's D-Bus services, linked into the user's own
  $XDG_DATA_HOME/dbus-1/services (a directory of the session bus's
  standard_session_servicedirs) followed by ReloadConfig -- so Nautilus,
  Settings, the Console and gnome-shell's helpers are activatable for this
  user only. Stale links from an older GNOME are removed first. The portal
  backend needs no system registration either: xdg-desktop-portal reads
  portal definitions and <desktop>-portals.conf from XDG_DATA_DIRS, which in
  this session includes the env (gnome.portal, gnome-portals.conf); the
  backend's systemd unit is in systemd.packages above.

  THE LOCK SCREEN IS OFF in these sessions. Unlocking goes through GDM's
  reauthentication channel (gnome-shell's ShellUserVerifier, Gdm.Client),
  and there is no GDM here -- greetd is the display manager -- so a locked
  GNOME could not be unlocked. The accounts pinned to it are passwordless
  anyway.

  NOT HERE, on purpose: a global glib-networking GIO module (the Hyprland
  sessions have none either; GNOME's apps carry it in their wrappers),
  gnome-keyring (no password to unlock it with, and its
  PAM module is epoch surface), gvfs and udisks2 (system-wide; Nautilus has
  local files and no mounts), evolution-data-server (the shell's calendar
  shows no events), at-spi (off system-wide on gb4), gnome-initial-setup and
  gnome-tour, geoclue app whitelists (no automatic timezone), the rfkill
  uaccess udev rule (airplane mode via NetworkManager only), mutter's udev
  rules (Broadwell/Skylake i915 ids only).
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.gnome;

  /*
    Everything here is for accounts the host's tuning does not serve
    (registry/types.nix `tuned`; guest and handoff), so all of it comes from
    the untuned set (my.tuning.untunedPkgs: plain upstream, from
    cache.nixos.org) -- the session, the shell, the apps, the portal, the
    launcher's own tools. Before, the classifier merely had not seen these
    names yet. Listed in my.tuning.untunedRoots below, so their use is never
    evidence for tuning the system's set either. No packages.nix in this
    feature: lookup.nix's Tier 3 would read it as anchors.
  */
  upkgs = config.my.tuning.untunedPkgs;

  pinned = lib.attrNames (lib.filterAttrs (_: u: u.desktop == "gnome") config.my.users);

  # The shell and what it cannot start without; cfg.packages are the apps.
  core = [
    upkgs.gnome-shell
    upkgs.gnome-session
    upkgs.gnome-settings-daemon
    upkgs.gsettings-desktop-schemas
    upkgs.xdg-desktop-portal-gnome
    upkgs.adwaita-icon-theme
    upkgs.gnome-backgrounds
  ];
  sessionPkgs = core ++ cfg.packages;

  env = upkgs.buildEnv {
    name = "gnome-session-env";
    paths = sessionPkgs;
    pathsToLink = [ "/bin" "/share" "/etc/xdg" ];
    ignoreCollisions = true;
  };

  # nixpkgs' extraInit loop, at evaluation time: each package's own schema dir.
  schemaDirs = lib.concatMapStringsSep ":" (p: "${p}/share/gsettings-schemas/${p.name}") sessionPkgs;

  overrides = upkgs.gnome.nixos-gsettings-overrides.override {
    favoriteAppsOverride = ''
      [org.gnome.shell]
      favorite-apps=[ ${lib.concatMapStringsSep ", " (a: "'${a}'") cfg.favoriteApps} ]
    '';
    extraGSettingsOverrides = ''
      [org.gnome.desktop.lockdown]
      disable-lock-screen=true
      disable-user-switching=true

      [org.gnome.desktop.screensaver]
      lock-enabled=false

      ${cfg.extraGSettingsOverrides}
    '';
  };

  fontsConf = upkgs.writeText "gnome-session-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
      <dir>${upkgs.adwaita-fonts}/share/fonts</dir>
    </fontconfig>
  '';

  launcher = upkgs.writeShellScriptBin "gnome-desktop-session" ''
    if [ $# -gt 0 ]; then
      echo "gnome-desktop-session takes no arguments" >&2
      exit 1
    fi
    # A pinned login (session-pin.nix) execs this INSTEAD of the rest of
    # /etc/profile; a pick from the greeter has been through it already.
    [ -n "''${__NIXOS_SET_ENVIRONMENT_DONE-}" ] || . /etc/set-environment

    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=GNOME
    export XDG_SESSION_DESKTOP=gnome
    export DESKTOP_SESSION=gnome
    export XDG_DATA_DIRS="${schemaDirs}:${env}/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
    export XDG_CONFIG_DIRS="${env}/etc/xdg''${XDG_CONFIG_DIRS:+:$XDG_CONFIG_DIRS}"
    export PATH="${env}/bin''${PATH:+:$PATH}"
    export NIX_GSETTINGS_OVERRIDES_DIR=${overrides}/share/gsettings-schemas/nixos-gsettings-overrides/glib-2.0/schemas
    export FONTCONFIG_FILE=${fontsConf}

    # The session's D-Bus services, for this user's bus only (see the header).
    services="''${XDG_DATA_HOME:-$HOME/.local/share}/dbus-1/services"
    ${upkgs.coreutils}/bin/mkdir -p "$services"
    for l in "$services"/*.service; do
      [ -L "$l" ] || continue
      case "$(${upkgs.coreutils}/bin/readlink "$l")" in
        /nix/store/*-gnome-session-env/*) ${upkgs.coreutils}/bin/rm -f "$l" ;;
      esac
    done
    for f in ${env}/share/dbus-1/services/*.service; do
      [ -e "$f" ] && ${upkgs.coreutils}/bin/ln -sfn "$f" "$services/"
    done
    ${upkgs.systemd}/bin/busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
      org.freedesktop.DBus ReloadConfig >/dev/null 2>&1 || true

    # --no-reexec: gnome-session would otherwise re-execute itself through
    # `$SHELL -l -c`, i.e. through /etc/profile again.
    exec ${upkgs.gnome-session}/bin/gnome-session --no-reexec
  '';
  launcherExe = "${launcher}/bin/gnome-desktop-session";

  systemdPkgs = [
    upkgs.gnome-session
    upkgs.gnome-shell
    upkgs.gnome-settings-daemon
    upkgs.xdg-desktop-portal-gnome
  ];

  entry =
    (upkgs.writeTextDir "share/wayland-sessions/gnome.desktop" ''
      [Desktop Entry]
      Name=GNOME
      Comment=The GNOME desktop
      Exec=${launcherExe}
      Type=Application
      DesktopNames=GNOME
    '').overrideAttrs
      { passthru.providedSessions = [ "gnome" ]; };
in
{
  options.my.gnome = {
    enable = lib.mkEnableOption ''
      GNOME as a session of its own (not services.desktopManager.gnome; see
      the header for why): a "GNOME" greeter entry, and the launcher behind the
      registry's session = { desktop = "gnome"; }. Nothing of it reaches other
      sessions' environment, PAM, D-Bus or /run/current-system/sw'';

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        gnome-control-center
        nautilus
        gnome-console
        gnome-text-editor
      ];
      defaultText = lib.literalExpression "with config.my.tuning.untunedPkgs; [ gnome-control-center nautilus gnome-console gnome-text-editor ]";
      description = ''
        Applications of the GNOME session, beyond the shell itself. In the
        session's data dirs, PATH and D-Bus services only -- not in
        environment.systemPackages, so no other session lists or activates
        them. From my.tuning.untunedPkgs, like the rest of the session.
      '';
    };

    favoriteApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "firefox.desktop"
        "org.gnome.Nautilus.desktop"
        "org.gnome.Console.desktop"
        "org.gnome.TextEditor.desktop"
      ];
      description = "Desktop file ids for the dash (org.gnome.shell favorite-apps default).";
    };

    extraGSettingsOverrides = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "More gsettings defaults for GNOME sessions (gschema.override syntax).";
    };

    internal.launcher = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = launcher;
      description = "The session launcher (bin/gnome-desktop-session), for tests.";
    };
  };

  config = lib.mkMerge [
    {
      # The pin is greetd's /etc/profile (session-pin.nix); the launcher
      # starts the session from that shell.
      my.internal.features.gnome = {
        requires = [ "greetd" ];
        enabledBy = cfg.enable;
      };

      assertions = [
        {
          assertion = pinned == [ ] || cfg.enable;
          message = "my.users (${lib.concatStringsSep ", " pinned}): session = { desktop = \"gnome\"; } needs my.gnome.enable on this host.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      services.displayManager.sessionPackages = lib.mkAfter [ entry ];

      systemd.packages = systemdPkgs;

      # As nixpkgs' gnome.nix and gnome-settings-daemon.nix: the session
      # monitor must not be restarted by a switch (that ends the session),
      # and XSettings serves the session's Xwayland clients.
      systemd.user.services.gnome-session-monitor = {
        restartIfChanged = false;
        overrideStrategy = "asDropin";
        enableDefaultPath = false;
      };
      systemd.user.targets.gnome-session-x11-services.wants = [ "org.gnome.SettingsDaemon.XSettings.service" ];
      systemd.user.targets.gnome-session-x11-services-ready.wants = [ "org.gnome.SettingsDaemon.XSettings.service" ];

      # What GNOME is broken without; already on wherever a desktop runs.
      programs.dconf.enable = true;
      security.polkit.enable = true;
      services.accounts-daemon.enable = true;
      services.upower.enable = lib.mkDefault true;

      # Not evidence for the system's tuning (refresh-tier1's cut).
      my.tuning.untunedRoots = [ launcher entry env overrides fontsConf ] ++ systemdPkgs;

      my.internal.sessionPins = lib.genAttrs pinned (_: {
        command = launcherExe;
        greeterOnly = true;
      });
    })
  ];
}
