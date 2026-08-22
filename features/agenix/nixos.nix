{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.my.agenix;
in
{
  /*
    Imported unconditionally, like every other feature: this only declares the
    `age.*` option tree, and agenix's activation script is a no-op while
    `age.secrets` is empty. `imports` is never a switch here -- see the
    feature-registration comment in flake.nix.
  */
  imports = [ inputs.feat-agenix.nixosModule ];

  options.my.agenix = {
    enable = lib.mkEnableOption ''
      agenix: age-encrypted secrets committed as ciphertext, decrypted at
      activation into /run/agenix (tmpfs, so plaintext never lands on disk)
    '';

    identityPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/etc/agenix/identity.txt" ];
      description = ''
        Private age identities used to DECRYPT at activation, in order.

        A path outside the flake, deliberately: this is the one secret agenix
        cannot itself protect -- the root of trust every secret manager needs.
        Never add it to the repo (the flake is public, and a git flake would
        copy it into the world-readable store).

        Not the usual /etc/ssh/ssh_host_ed25519_key: agenix's default assumes
        the host runs sshd and therefore HAS host keys.
        galaxybook4-pro360 does not (only victus-15 sets
        services.openssh.enable), so there is nothing to encrypt to. A
        dedicated age identity avoids running an ssh daemon purely to
        manufacture a keypair.

        Generate once per host, as root:
          umask 077
          mkdir -p /etc/agenix
          ${lib.getExe pkgs.age}-keygen -o /etc/agenix/identity.txt
          # the printed "Public key: age1..." line goes in secrets.nix

        WHAT THIS DOES AND DOES NOT BUY, stated plainly because it is easy to
        overestimate: ciphertext becomes safe to commit to a PUBLIC repo, and
        plaintext exists only in tmpfs at runtime. It does NOT protect against
        someone holding the disk -- this identity sits unencrypted on an
        unencrypted filesystem. Disk encryption is the complement, not the
        substitute.
      '';
    };
  };

  config = lib.mkMerge [
    /*
      Declared UNCONDITIONALLY, outside the mkIf, so features/_meta can see
      this feature exists even while it is off. `present` there tests the
      declaration attrset, not the directory -- register nothing and a
      dependent gets "requires 'agenix', which is not present in features/"
      even though the directory is right here. Same shape as features/dms.
    */
    { my.internal.features.agenix.enabledBy = cfg.enable; }

    (lib.mkIf cfg.enable {
    age.identityPaths = cfg.identityPaths;

    environment.systemPackages = [
      # `agenix -e age/<name>.age` to create/edit a secret; reads secrets.nix
      # at the repo root for the recipient list.
      inputs.feat-agenix.packages.${pkgs.stdenv.hostPlatform.system}.agenix
      # age/age-keygen for the bootstrap identity above, and ssh-to-age for
      # converting an ssh host key to an age recipient if a host ever grows one.
      pkgs.age
      pkgs.ssh-to-age
    ];
    })
  ];
}
