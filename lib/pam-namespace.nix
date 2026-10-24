/*
  pam_namespace that reads /etc/security/namespace.conf.

  nixpkgs builds linux-pam with sysconfdir = $out/etc, and pam_namespace has
  no argument for another file, so the /etc/security/namespace.conf a module
  writes is never read: pam_namespace finds the package's own empty default,
  does nothing and returns success -- no error anywhere (found by
  tests/guest-overlay-vm.nix: `findmnt /nix/store` empty in a guest's su
  session). This copy looks in /etc instead; take only pam_namespace.so from
  it, so nothing else in the system moves. Shared by every feature that
  polyinstantiates (features/nix/guest-overlay, features/session/gl-namespace).

  Usage: modulePath = "${import ../../../lib/pam-namespace.nix { inherit config; }}/lib/security/pam_namespace.so";
*/
{ config }:

config.security.pam.package.overrideAttrs (o: {
  pname = "${o.pname or "linux-pam"}-namespace-etc";
  postPatch = (o.postPatch or "") + ''
    substituteInPlace modules/pam_namespace/pam_namespace.h \
      --replace-fail '(SCONFIG_DIR "/namespace' '("/etc/security/namespace'
  '';
})
