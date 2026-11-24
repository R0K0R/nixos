/*
  Logins the primary user can USE but not READ: the one place for every credential the DMS planner and the
  user's tools need (school sites, Notion, and whatever comes next). Built for the planner, whose Claude
  session runs as that user, often with permission prompts off: anything the user's uid can open, Claude can
  open, so a credentials file it is merely asked not to read protects nothing.

    auth              a system user with no shell and no home. It alone can read the secrets.
    the secrets       /run/agenix/<service>-credentials, auth's, 0400 (tmpfs), one per service
    the programs      one fixed program per service (services/<name>.py, a store path, so it cannot be edited)
                      that reads its secret and prints ONLY what the caller may have: a session cookie for the
                      school sites, an API response for Notion. See each file's header for its rules.
    the sudo rules    <primaryUser> may run exactly those programs as `auth`, without a password. Not root: the
                      user's own sudo still wants a password, so neither the rules nor this file can be changed
                      without one.
    auth (cmd)        the user-facing wrapper: `auth <service> ...`, e.g. `auth ksa ksain`,
                      `auth notion GET /v1/users/me`.

  Adding a service: write services/<name>.py (it gets its secret's path as @credFile@), add <name> to
  `knownServices` below, encrypt its KEY=value file for galaxybook (secrets.nix), and set
  my.auth.services.<name>.credentialsFile on the host.

  The limit, by design: whoever holds what a program prints (a cookie, an API answer) can use it. The secret
  itself never leaves the program.

  Was `ksa-auth` (school logins only) until 2026-11-21; the KakaoTalk login is still deliberately not here
  (its client is a GUI running as the user, and the wine prefix keeps its own login anyway).
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.auth;
  user = "auth";

  # service name -> what it is, for the option docs and the wrapper's usage line
  knownServices = {
    ksa = "ksain.kr and my.ksa.hs.kr logins (KSAIN_ID, KSAIN_PW, MYKSA_ID, MYKSA_PW); prints the session";
    notion = "the Notion integration token (NOTION_TOKEN); proxies Notion API calls to api.notion.com";
  };

  enabled = lib.filterAttrs (_: s: s.credentialsFile != null) cfg.services;

  program = name: pkgs.writeTextFile {
    name = "auth-${name}";
    executable = true;
    destination = "/bin/auth-${name}";
    # -I: no PYTHON* variables, no user site-packages, no script-dir/cwd on sys.path. sudo's env_reset already
    # drops most of that; this does not depend on it.
    text = "#!${pkgs.python3}/bin/python3 -I\n" + lib.replaceStrings
      [ "@credFile@" ]
      [ config.age.secrets."${name}-credentials".path ]
      (builtins.readFile (./services + "/${name}.py"));
  };

  programs = lib.mapAttrs (name: _: program name) enabled;

  wrapper = pkgs.writeShellScriptBin "auth" ''
    svc="''${1:-}"
    case "$svc" in
    ${lib.concatStrings (lib.mapAttrsToList (name: p: ''
      ${name}) shift; exec /run/wrappers/bin/sudo -n -u ${user} -- ${p}/bin/auth-${name} "$@" ;;
    '') programs)}
      *) echo "usage: auth <service> ...   services: ${lib.concatStringsSep ", " (lib.attrNames programs)}" >&2; exit 2 ;;
    esac
  '';
in
{
  options.my.auth = {
    enable = lib.mkEnableOption "logins (school sites, Notion, ...) the primary user can use but not read";

    services = lib.mkOption {
      default = { };
      description = "Per service: its agenix-encrypted KEY=value file. Known services: "
        + lib.concatStringsSep "; " (lib.mapAttrsToList (n: d: "${n} (${d})") knownServices) + ".";
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options.credentialsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "../../age/${name}-credentials.age";
          description = "Decrypted at activation to /run/agenix/${name}-credentials, owned by auth, 0400.";
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = knownServices ? ${name};
      message = "my.auth.services.${name}: no program for it (known: ${lib.concatStringsSep ", " (lib.attrNames knownServices)})";
    }) cfg.services;

    # Same reason as emacs.authinfo: an age.secrets entry on a host with agenix off evaluates, builds and
    # switches, and decrypts nothing.
    my.internal.features."auth" = {
      requires = [ "agenix" ];
      enabledBy = cfg.enable;
    };

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      description = "holds the login credentials (school sites, Notion)";
    };
    users.groups.${user} = { };

    age.secrets = lib.mapAttrs' (name: s: lib.nameValuePair "${name}-credentials" {
      file = s.credentialsFile;
      owner = user;
      group = user;
      mode = "0400";
    }) enabled;

    security.sudo.extraRules = [{
      users = [ config.my.internal.primaryUser ];
      runAs = user;
      commands = lib.mapAttrsToList (name: p: {
        command = "${p}/bin/auth-${name}";
        options = [ "NOPASSWD" ];
      }) programs;
    }];

    environment.systemPackages = [ wrapper ];
  };
}
