/*
  adb to the user's phone, with a gate in front of the dangerous half.

  Wireless debugging is a strong key to a phone: a connected adb shell can type into any open app, install
  apps and read shared storage. adb keeps its key in ~/.android and runs a server on localhost:5037 that ANY
  local account can use, so under the DMS planner (whose Claude session runs as the primary user, usually with
  permission prompts off) a key in the user's home would be a key Claude holds. So:

    phone-adb         a system user that alone holds the adb key and the adb server. The server listens on a
                      Unix socket in a directory only that user can enter, not on :5037.
    phone-adb-watch   a service as that user: when the phone advertises Wireless debugging (found through
                      Avahi, since this adb build has no mDNS of its own) it connects. Nothing is exposed
                      unless the user has switched Wireless debugging on, on the phone.
    phone-adb         (command) the client: one sudo rule runs phone-adb-run as that user. Free tier: connect,
                      status, info, screenshot, notifications, app list, ls/pull under shared storage.
    the grant         `shell` and `push` need a grant that only phone-adb-grant (root) can write, and it is
                      reached only through a polkit prompt the user answers (`phone-adb-authorize`, run by
                      `phone adb authorize`). It lasts for a session: it ends after an idle period or a
                      maximum time, or when revoked (`phone-adb-revoke`, no password: closing is never risky).

  The polkit action is auth_self (the user's own password or fingerprint) and has a prompt that says what it
  allows. Pairing the phone is a separate one-time step that needs the code on the phone's screen.
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.phone-adb;
  user = "phone-adb";
  home = "/var/lib/phone-adb";
  # Short on purpose: a Unix socket path is capped near 108 bytes.
  sock = "/run/phone-adb-srv/adb.sock";
  grantFile = "/run/phone-adb/grant.json";
  stateDir = "/run/phone-adb-state";
  human = config.my.internal.primaryUser;

  subst = lib.replaceStrings
    [ "@adb@" "@avahiBrowse@" "@sock@" "@home@" "@grantFile@" "@stateDir@" "@idleMinutes@" "@maxHours@" ]
    [ "${pkgs.android-tools}/bin/adb" "${pkgs.avahi}/bin/avahi-browse" sock home grantFile stateDir
      (toString cfg.idleMinutes) (toString cfg.maxHours) ];

  script = name: file: pkgs.writeTextFile {
    inherit name;
    executable = true;
    destination = "/bin/${name}";
    # -I: no PYTHONPATH / user site / cwd on sys.path. Both programs run with elevated or
    # separated rights, so they take nothing from their environment.
    text = "#!${pkgs.python3}/bin/python3 -I\n" + subst (builtins.readFile file);
  };

  runner = script "phone-adb-run" ./phone_adb.py;
  grantHelper = script "phone-adb-grant" ./phone_adb_grant.py;

  client = pkgs.writeShellScriptBin "phone-adb" ''
    exec /run/wrappers/bin/sudo -n -u ${user} -- ${runner}/bin/phone-adb-run "$@"
  '';
  authorize = pkgs.writeShellScriptBin "phone-adb-authorize" ''
    exec /run/wrappers/bin/pkexec ${grantHelper}/bin/phone-adb-grant --grant "$@"
  '';
  revoke = pkgs.writeShellScriptBin "phone-adb-revoke" ''
    exec /run/wrappers/bin/sudo -n -u root -- ${grantHelper}/bin/phone-adb-grant --revoke
  '';

  # pkexec uses an action's own prompt when the program matches its exec.path annotation.
  policy = pkgs.writeTextFile {
    name = "phone-adb-polkit";
    destination = "/share/polkit-1/actions/org.dms.phone-adb.policy";
    text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
        "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
      <policyconfig>
        <vendor>DMS planner</vendor>
        <action id="org.dms.phone-adb.grant">
          <description>Open an adb shell session to your phone</description>
          <message>Allow programs running as you, including Claude Code, to control your phone through adb for this session?</message>
          <defaults>
            <allow_any>no</allow_any>
            <allow_inactive>no</allow_inactive>
            <allow_active>auth_self</allow_active>
          </defaults>
          <annotate key="org.freedesktop.policykit.exec.path">${grantHelper}/bin/phone-adb-grant</annotate>
          <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
        </action>
      </policyconfig>
    '';
  };
in
{
  options.my.phone-adb = {
    enable = lib.mkEnableOption "adb to the phone, with its key held by a separate account and a polkit-gated full shell";
    idleMinutes = lib.mkOption {
      type = lib.types.ints.between 1 240;
      default = 30;
      description = "A grant ends after this many minutes without use.";
    };
    maxHours = lib.mkOption {
      type = lib.types.ints.between 1 24;
      default = 8;
      description = "A grant ends this many hours after it was given, however busy.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.services.avahi.enable;
      message = "my.phone-adb finds the phone through Avahi: enable services.avahi (my.discovery)";
    }];

    # The grant prompt is `pkexec`, which only works as a setuid wrapper. In this nixpkgs that wrapper is a
    # separate switch (enablePkexecWrapper, off by default; security.polkit.enable alone defines it as
    # disabled). This adds one setuid-root binary to the system: polkit's pkexec, the standard way to get a
    # polkit prompt for a root helper, and the reason it is kept narrow here is that the helper it runs
    # (phone-adb-grant) does only three things and refuses --grant without a polkit-authenticated user.
    security.polkit.enable = lib.mkDefault true;
    security.polkit.enablePkexecWrapper = lib.mkDefault true;

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = home;
      createHome = true;
      homeMode = "0700";
      description = "holds the adb key and server for the phone";
    };
    users.groups.${user} = { };

    systemd.tmpfiles.rules = [
      "d /run/phone-adb 0755 root root -" # the grant, written by root only
      "d /run/phone-adb-srv 0700 ${user} ${user} -" # the adb server's private socket
      "d /run/phone-adb-state 0700 ${user} ${user} -" # when the grant was last used
    ];

    systemd.services.phone-adb-watch = {
      description = "Connect adb to the phone while its Wireless debugging is on";
      wantedBy = [ "multi-user.target" ];
      wants = [ "avahi-daemon.service" ];
      after = [ "avahi-daemon.service" "network.target" ];
      environment.HOME = home;
      serviceConfig = {
        User = user;
        Group = user;
        ExecStart = "${runner}/bin/phone-adb-run watch";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ home "/run/phone-adb-srv" "/run/phone-adb-state" ];
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
      };
    };

    security.sudo.extraRules = [
      {
        users = [ human ];
        runAs = user;
        commands = [{ command = "${runner}/bin/phone-adb-run"; options = [ "NOPASSWD" ]; }];
      }
      {
        # Closing and reading the grant need no password. Opening it (--grant) is NOT here: only polkit.
        users = [ human ];
        runAs = "root";
        commands = [
          { command = "${grantHelper}/bin/phone-adb-grant --revoke"; options = [ "NOPASSWD" ]; }
          { command = "${grantHelper}/bin/phone-adb-grant --status"; options = [ "NOPASSWD" ]; }
        ];
      }
    ];

    environment.systemPackages = [ client authorize revoke policy ];
  };
}
