{ config, lib, pkgs, ... }:

let
  cfg = config.my.copykiller-login;
  user = "copykiller-auth";

  /*
    The login helper. It lives in the store, so it is immutable: the one
    command the sudo rule below grants cannot be edited into something else
    by the account that is allowed to run it. URL, credentials path and CA
    bundle are baked in at build time, never taken from argv or env.
  */
  copykiller-login = pkgs.writeTextFile {
    name = "copykiller-login";
    destination = "/bin/copykiller-login";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3 -I
    '' + builtins.replaceStrings
      [ "@credentials@" "@cafile@" ]
      [ config.age.secrets.copykiller-credentials.path "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ]
      (builtins.readFile ./login.py);
  };
in
{
  options.my.copykiller-login = {
    enable = lib.mkEnableOption ''
      copykiller-login: logs in to ksa.copykiller.com as a dedicated system user
      that alone can read the credentials, and prints only the session cookies.
      Lets an agent running as a normal user (the copykiller MCP server) get a
      session without ever being able to read the password
    '';

    credentialsSecret = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression "../../age/copykiller-credentials.age";
      description = ''
        agenix file whose plaintext is two lines:
          COPYKILLER_ID=<email>
          COPYKILLER_PW=<password>
        Decrypted to /run/agenix/copykiller-credentials, owner ${user}, 0400.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "r0k0r" ];
      description = "Accounts allowed to run copykiller-login (and nothing else) as ${user}.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.my.agenix.enable;
        message = "my.copykiller-login requires my.agenix.enable";
      }
    ];

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      description = "copykiller-login credential holder";
    };
    users.groups.${user} = { };

    age.secrets.copykiller-credentials = {
      file = cfg.credentialsSecret;
      owner = user;
      group = user;
      mode = "0400";
    };

    environment.systemPackages = [ copykiller-login ];

    /*
      Exactly one command, as exactly one non-root user, without a password.
      Both spellings are listed: the store path (what the profile symlink
      resolves to) and the stable profile path callers actually type.
      env_reset (sudo's default) drops the caller's environment; the helper
      ignores env anyway. Changing this rule needs `sudo nixos-rebuild`.
    */
    security.sudo.extraRules = [
      {
        users = cfg.users;
        runAs = user;
        commands = map (command: { inherit command; options = [ "NOPASSWD" ]; }) [
          "${copykiller-login}/bin/copykiller-login"
          "/run/current-system/sw/bin/copykiller-login"
        ];
      }
    ];
  };
}
