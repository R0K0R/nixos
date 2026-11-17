/*
  The SYSTEM half of photography: the grant for USB cameras. gphoto2 talks to
  a camera over raw USB, which needs libgphoto2's udev rules -- they put every
  camera it knows in the `camera` group -- and the account in that group.
  Done here rather than with programs.gphoto2, which also installs gphoto2
  system-wide: the program is the home half's (my.photography in a home repo,
  with darktable, RawTherapee and the rest), the system only grants access.
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.photography;
in
{
  options.my.photography = {
    enable = lib.mkEnableOption "USB camera access for gphoto2: libgphoto2's udev rules and the camera group";
    users = import ../../../lib/user-scope.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    services.udev.packages = [ pkgs.libgphoto2 ];
    users.groups.camera = { };
    users.users = lib.genAttrs cfg.users (_: { extraGroups = [ "camera" ]; });
  };
}
