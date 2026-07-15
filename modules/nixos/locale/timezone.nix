{ lib, ... }:

{
  /*
    Travel laptop: keep the system clock's timezone correct after flying,
    without a manual `timedatectl set-timezone`. automatic-timezoned uses
    geoclue2 (already enabled in desktop/session-services.nix) + its own
    demo agent to get a location fix, then systemd-timedated to apply the
    zone. It sets time.timeZone = null at normal priority once enabled, so
    the fallback below must be mkDefault (lower priority) -- otherwise the
    module raises a conflict error (it explicitly checks for this: see
    services.automatic-timezoned's option doc).
  */
  time.timeZone = lib.mkDefault "Asia/Seoul";
  services.automatic-timezoned.enable = true;
}
