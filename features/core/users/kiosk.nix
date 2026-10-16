/*
  session = { kiosk = "<package>"; }: a greetd session that runs one program
  under cage and nothing else -- the handover type's firefox.

  Built the way features/session/fallback-session builds its session: a
  wayland-sessions entry whose Exec is a script from the SYSTEM package set.
  cage and the program are the host's pkgs (the registry resolves the
  attribute name against them), so a kiosk user needs no home-manager
  generation and no nix access to get a working session -- which is the
  point, since the handover type has neither.

  One entry per distinct package, not per user: two handover accounts on one
  host with the same browser share "Kiosk (firefox)". `cage -s` keeps VT
  switching, so the machine's owner can still reach a text console.

  NOT ENFORCED: that a kiosk user picks THIS session. wayland-sessions are
  global, and which entry a login gets is the greeter's choice (dms-greeter
  remembers the last one per user). Picking it as someone else is harmless --
  it runs the program as that person. Pinning a user to a session needs either
  the greeter's cooperation or wrapping every other session's Exec in a
  per-user refusal; TODO, see docs/multiuser-design.md.
*/
{ config, lib, pkgs, ... }:

let
  kioskPkgs = lib.unique (
    lib.mapAttrsToList (_: u: u.kiosk) (lib.filterAttrs (_: u: u.kiosk != null) config.my.users)
  );

  entry =
    pkg:
    let
      prog = lib.getExe pkg;
      name = "kiosk-${baseNameOf prog}";
      run = pkgs.writeShellScript name ''
        exec ${lib.getExe pkgs.cage} -s -- ${prog}
      '';
    in
    (pkgs.writeTextDir "share/wayland-sessions/${name}.desktop" ''
      [Desktop Entry]
      Name=Kiosk (${baseNameOf prog})
      Comment=${baseNameOf prog} alone, full screen, nothing else
      Exec=${run}
      Type=Application
    '').overrideAttrs
      { passthru.providedSessions = [ name ]; };
in
{
  config = lib.mkIf (kioskPkgs != [ ]) {
    services.displayManager.sessionPackages = map entry kioskPkgs;
  };
}
