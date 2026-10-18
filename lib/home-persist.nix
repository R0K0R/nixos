/*
  my.persist in a HOME: what this user wants to survive when their home is
  impermanent (registry home = "impermanent", features/core/impermanence).
  Each user suggests their own list; the system merges it at boot with what
  features declare (my.state.user) and the always-kept home-manager state.

  Paths are relative to the home ("KSA", ".ssh", ".config/gh/hosts.yml"). The
  list reaches the system as data: activation writes it to
  <persistRoot>/home/<user>/.persist.json, and the next boot binds every entry
  from <persistRoot>/home/<user>/<path> -- so a change takes effect at the
  next boot, and a directory added here starts empty unless its content is
  copied into <persistRoot>/home/<user>/ first.

  In every home (sharedModules) so a user module may always set it. Only an
  impermanent home writes anything: elsewhere this changes nothing.
*/
{ config, lib, osConfig, pkgs, ... }:

let
  cfg = config.my.persist;
  name = config.home.username;
  imp = osConfig.my.impermanence or { enable = false; };
  impermanent = (imp.enable or false) && (osConfig.my.users.${name}.impermanentHome or false);
  manifest = pkgs.writeText "persist-${name}.json" (builtins.toJSON { inherit (cfg) directories files; });
  dest = "${imp.persistRoot or "/persist"}/home/${name}/.persist.json";
in
{
  options.my.persist = {
    directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "KSA" "git_shit" ".ssh" ".mozilla/firefox" ];
      description = "Directories (relative to the home) kept across reboots when the home is impermanent.";
    };
    files = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ ".config/gh/hosts.yml" ];
      description = "Single files kept across reboots.";
    };
  };

  config = lib.mkIf impermanent {
    assertions = [
      {
        assertion = cfg.directories != [ ] || cfg.files != [ ];
        message = "my.persist is empty for ${name}, whose home is wiped at every boot: everything in it would be lost. List what to keep (KSA, .ssh, ...).";
      }
      {
        assertion = lib.all (p: !(lib.hasPrefix "/" p) && !(lib.hasInfix ".." p)) (cfg.directories ++ cfg.files);
        message = "my.persist: paths are relative to the home and stay inside it.";
      }
    ];
    # The next boot reads it; persist-home-<user> refuses anything unsafe again.
    home.activation.persistManifest = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run install -m 0644 ${manifest} ${lib.escapeShellArg dest}
    '';
  };
}
