{ config, inputs, lib, ... }:

let
  cfg = config.my.nix-settings;
in
{
  options.my.nix-settings = {
    enable = lib.mkEnableOption "flakes, the upstream-pinned registry, and GC policy";

    allowUnfree = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Allow unfree packages. Policy, not tuning -- it used to live inside
        tuning/pkgs-config.nix, a file full of meteorlake qtbase patching, so a
        host that did not want those patches silently lost unfree as well.
      '';
    };

    substituters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "https://cache.nixos.org" ];
      description = "Binary caches. The remote-builder feature adds peer stores on top of this.";
    };

    trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
      description = "Public keys for `substituters`.";
    };

    trustedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users allowed to pass privileged nix options (substituters, builders, …).";
    };

    secretKeyFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Private signing keys, so this machine's store can be trusted as a
        substituter by its peers. Read from outside the store.

        Prefer signingKeySecret below, which produces one of these paths from
        an age file instead of from an untracked file placed by hand.
      '';
    };

    signingKeySecret = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "../../age/nix-signing-key-victus-15.age";
      description = ''
        An agenix file holding this machine's binary-cache signing key, of the
        form produced by `nix-store --generate-binary-cache-key`. Decrypted to
        /run/agenix/nix-signing-key and appended to secretKeyFiles.

        PER HOST, never shared. The public half is what peers list in
        trusted-public-keys, so two machines sharing one signing key would be
        indistinguishable to anything consuming their stores -- the point of
        the key is to say WHICH store vouched for a path.

        Failure here is recoverable and non-fatal, unlike a password secret:
        nix simply cannot sign, so peers decline to substitute from this
        machine and build the path themselves.
      '';
    };

    gc.automatic = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Automatic garbage collection. Off while the pseudo-cross fork project is
        active: failed switch attempts leave days' worth of build artifacts
        unrooted by design, and persistent=true meant a reboot fired the missed
        weekly timer -- one boot GC'd ~3-4k locally built paths (2026-07-08).
        GC stays a manual decision until the store stops being expensive to
        reproduce. When re-enabling, the old settings were:
          dates = "weekly"; options = "--delete-older-than 14d"; persistent = true;
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.config.allowUnfree = cfg.allowUnfree;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Point nix-shell / nix run / the flake registry at the unpatched upstream
    # nixpkgs so derivation hashes match what Hydra cached.  nixpkgs-upstream is
    # a separate input that --override-input nixpkgs path:... never touches.
    # nixpkgs-flake.nix also sets nix.registry.nixpkgs; mkForce wins.
    nix.registry.nixpkgs = lib.mkForce { flake = inputs.nixpkgs-upstream; };
    nix.nixPath = lib.mkForce [ "nixpkgs=${inputs.nixpkgs-upstream}" ];

    nix.gc.automatic = cfg.gc.automatic;

    # mkDefault so the remote-builder feature's own substituter list (which adds
    # peer stores) wins where both are enabled, rather than conflicting.
    nix.settings.substituters = lib.mkDefault cfg.substituters;
    nix.settings.trusted-public-keys = lib.mkDefault cfg.trustedPublicKeys;
    nix.settings.trusted-users = lib.mkIf (cfg.trustedUsers != [ ]) cfg.trustedUsers;
    /*
      Same shape as features/openvpn's profileSecret: the age.secrets entry is
      declared only when the option is set, because a declared entry on a host
      without agenix builds a system whose activation fails on a missing
      identity.
    */
    age.secrets = lib.mkIf (cfg.signingKeySecret != null) {
      nix-signing-key = {
        file = cfg.signingKeySecret;
        # nix-daemon runs as root and reads this lazily, only when signing.
        mode = "0400";
      };
    };

    nix.settings.secret-key-files =
      let
        keys = cfg.secretKeyFiles ++ lib.optional (cfg.signingKeySecret != null) "/run/agenix/nix-signing-key";
      in
      lib.mkIf (keys != [ ]) keys;

    assertions = [
      {
        assertion = cfg.signingKeySecret == null || config.my.agenix.enable;
        message = "my.nix-settings.signingKeySecret requires my.agenix.enable";
      }
    ];
  };
}
