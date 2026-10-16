/*
  home = "tmpfs" (the handover type): a home that exists for one stretch of
  logins and is gone afterwards.

  WHEN IT IS MOUNTED. Not at boot. A boot-time tmpfs lives until the next
  reboot, so on a laptop that is suspended rather than shut down the second
  guest of the week would inherit the first one's browser profile. Cleaning
  it at logout from a PAM close_session hook was the other obvious design
  and is the fragile one: pam_exec at close runs once per SESSION, has to
  decide by itself whether this was the user's last one, and is skipped
  outright when the session process is killed rather than exiting.

  Instead the home is tied to the one unit whose lifetime IS "this user is
  logged in": user@<uid>.service, the user's systemd manager. logind starts
  it at the first session (pam_systemd waits for it before the login
  continues, so the mount is in place before greetd or login chdir()s into
  the home) and stops it after the last one ends. This is the same lifetime
  logind already gives /run/user/<uid> (user-runtime-dir@), for the same
  reason. The mount is
    RequiredBy + Before user@<uid>.service   mounted before the manager starts;
    PartOf user@<uid>.service                unmounted when it stops.

  WHY A LINGERING PROCESS CANNOT KEEP A STALE HOME. Two ways it could:

    1. Keep the USER alive, so user@ never stops and the next login joins
       the same manager and the same mount. NixOS defaults KillUserProcesses
       to false (tmux/nohup survive logout), and an abandoned session scope
       keeps the user around. So for tmpfs users -- and only them,
       KillOnlyUsers -- logind kills the session's processes at logout.
       Lingering (users.users.<n>.linger) would keep user@ up by design and
       is refused by an assertion.
    2. Hold the mount busy, so the stop fails and the old tmpfs stays where
       the next login looks. LazyUnmount: the mountpoint is detached at once
       whatever still has files open, the next login mounts a NEW tmpfs, and
       the old one's memory goes when its last holder does. A straggler can
       keep its own copy of the old home; it cannot hand it to anyone.

  What it does not cover, documented rather than pretended:
    * logind's UserStopDelaySec (default 10 s) keeps user@ -- and so the
      home -- across a re-login inside that window. It is a global logind
      setting; zeroing it for every user of the host to close a 10 s window
      is not this file's call.
    * /tmp, /var/tmp: shared, out of scope by the threat model
      (docs/multiuser-design.md). /dev/shm and SysV IPC are already removed
      at logout (logind RemoveIPC=yes, the default); XDG_RUNTIME_DIR is
      user-runtime-dir@'s own tmpfs.

  FAIL-CLOSED. createHome = false (features/core/users/nixos.nix), so the
  directory underneath the mount is the one systemd creates for a
  mountpoint: root-owned, 0755. If the tmpfs fails to mount the user gets
  an unwritable home, never a persistent one.
*/
{ config, lib, ... }:

let
  tmpfsUsers = lib.filterAttrs (_: u: u.tmpfsHome != null) config.my.users;

  uidOf = n: config.users.users.${n}.uid;
  gidOf = n: config.users.groups.${config.users.users.${n}.group}.gid;
in
{
  config = lib.mkIf (tmpfsUsers != { }) {
    systemd.mounts = lib.mapAttrsToList (
      n: u:
      let
        manager = "user@${toString (uidOf n)}.service";
      in
      {
        description = "tmpfs home of ${n} (fresh per login)";
        what = "tmpfs";
        where = config.users.users.${n}.home;
        type = "tmpfs";
        options = lib.concatStringsSep "," [
          "size=${u.tmpfsHome.size}"
          "mode=0700"
          "uid=${toString (uidOf n)}"
          "gid=${toString (gidOf n)}"
          "nosuid"
          "nodev"
        ];
        mountConfig.LazyUnmount = true;
        unitConfig.PartOf = [ manager ];
        before = [ manager ];
        requiredBy = [ manager ];
      }
    ) tmpfsUsers;

    services.logind.settings.Login = {
      KillUserProcesses = true;
      # With KillUserProcesses on, logind kills ONLY these users' sessions
      # (logind.conf(5)); everyone else keeps tmux and nohup across logout.
      KillOnlyUsers = lib.concatStringsSep " " (lib.attrNames tmpfsUsers);
    };

    assertions = lib.concatLists (
      lib.mapAttrsToList (n: _: [
        {
          assertion = uidOf n != null;
          message = "my.users.${n}.tmpfsHome needs a pinned uid: the mount is bound to user@<uid>.service and sets uid=.";
        }
        {
          assertion = gidOf n != null;
          message = "my.users.${n}.tmpfsHome: the primary group ${config.users.users.${n}.group} has no fixed gid for the mount's gid=.";
        }
        {
          assertion = (config.users.users.${n}.linger or null) != true;
          message = "my.users.${n}: a tmpfs home cannot linger -- a lingering user manager never stops, so the home would never be cleared.";
        }
        {
          assertion = !((config.home-manager.users or { }) ? ${n});
          message = "my.users.${n}: a tmpfs home has no home-manager generation to activate into it (session must not be home-manager).";
        }
      ]) tmpfsUsers
    );
  };
}
