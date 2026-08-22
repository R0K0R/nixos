/*
  User accounts as data, and the ONE place in the repo that turns a feature's
  packages into some particular person's packages.

  WHAT THIS REPLACES: features/user-r0k0r/, plus a literal `r0k0r` in 27 other
  places. The name was load-bearing in three different ways, and each was its
  own bug:

    * 13 features wrote `users.users.r0k0r.packages` directly. That DECLARES the
      account, so a host that never enabled the user feature still got an r0k0r
      with 21 packages, `isNormalUser = false` and `isSystemUser = false` --
      which trips NixOS's "exactly one of isSystemUser and isNormalUser must be
      set". Found on a host whose only user was meant to be someone else.

    * lib/home-manager.nix hardcoded `users.r0k0r = { }`, so home-manager built
      an r0k0r on every host regardless of who lived there.

    * A per-user identity (`home.username`) was being set from a home module in
      `sharedModules`. sharedModules apply to EVERY user, so that module set
      benjamin's name inside r0k0r's home config and the two definitions
      collided. The rule this teaches is at the bottom of this comment.

  THE DIRECTION IS INVERTED. Features no longer name an account; they contribute
  to `my.packages.perUser`, keyed by whichever accounts their own `users` option
  names. This file is the only consumer. Besides removing the bugs above it is
  what makes a feature giftable: a feature that says `users.users.r0k0r.packages`
  silently creates an r0k0r in a stranger's config, and one that says
  `my.packages.perUser` does not.

  PRIMARY IS A PER-USER FLAG, not a top-level `my.users.primary` string, because
  `my.users` is an attrsOf -- a top-level `primary` would be indistinguishable
  from an account named "primary". The assertion below enforces exactly one.

  RULE, learned the hard way: anything PER-USER must be generated into
  `home-manager.users.<name>` (see lib/home-manager.nix), never placed in
  `sharedModules`. sharedModules can only carry what is true of every user.
  `home.username` and `home.stateVersion` are both per-user and both belong to
  the generator.
*/
{ config, lib, ... }:

let
  cfg = config.my.users;

  primaries = lib.attrNames (lib.filterAttrs (_: u: u.primary) cfg);
in
{
  options.my.users = lib.mkOption {
    default = { };
    description = ''
      Human accounts on this host, keyed by username.

      Declaring an account creates it -- there is deliberately no `enable` here.
      A host lists the people who use it, and `my.users` is that list; an
      account that should not exist is deleted rather than switched off. (This
      differs from features, where registration and activation are separate
      because every feature is imported on every host.)
    '';
    example = lib.literalExpression ''
      {
        r0k0r = { primary = true; extraGroups = [ "wheel" ]; };
        benjamin.description = "Benjamin S.H. Lee";
      }
    '';
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            primary = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                The account features apply to by default. Exactly one account
                must set this -- it is what `my.<feature>.users` defaults to,
                so with none or several the default is not well defined.
              '';
            };

            home = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Give this account a home-manager configuration. False for an
                account that should exist without one -- a service identity, or
                a second human who wants their dotfiles left alone.
              '';
            };

            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "GECOS field -- the human's actual name.";
            };

            uid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = ''
                Pin the uid. Worth doing BEFORE a host grows a second account:
                without it uids are assigned in declaration order, so adding a
                user can renumber an existing one and leave every file on disk
                owned by the wrong person.
              '';
            };

            extraGroups = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "wheel" "networkmanager" "video" "audio" ];
              description = "Groups beyond the account's own. `wheel` is what grants sudo.";
            };

            hashedPasswordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "/etc/nixos/secrets/hashed-password-r0k0r";
              description = ''
                Path to a hashed-password file, read at activation from OUTSIDE
                the Nix store. Null leaves password management to `passwd`.

                Never builtins.readFile this -- that copies the hash into the
                world-readable store.
              '';
            };

            shell = lib.mkOption {
              type = lib.types.nullOr lib.types.package;
              default = null;
              description = "Login shell. Null keeps the NixOS default.";
            };

            stateVersion = lib.mkOption {
              type = lib.types.str;
              default = "26.05";
              description = ''
                home-manager compatibility version (HM modules/misc/version.nix).
                Per-account, because accounts are created at different times.
              '';
            };
          };
        }
      )
    );
  };

  options.my.internal.primaryUser = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = ''
      The primary account's name, for features that need to default an option to
      "whoever this machine belongs to" -- a greeter reading someone's theme
      state, a gesture daemon, an agenix secret's owner.

      Read-only and derived: the primary is designated by
      `my.users.<name>.primary`, and the assertion below guarantees exactly one,
      so this is total wherever any account exists. Features read this rather
      than re-deriving it, so there is one definition of "primary" in the repo.
    '';
  };

  config = lib.mkMerge [
    /*
      Registered unconditionally so features/_meta can see this exists even on
      a host that declares no accounts -- `present` there tests the declaration
      attrset, not the directory.
    */
    { my.internal.features.users.enabledBy = cfg != { }; }

    {
      /*
        Guarded so the error surfaces as the assertion below -- which explains
        what to do -- rather than as `head: empty list` from whichever feature
        happened to force this default first.
      */
      my.internal.primaryUser = if primaries == [ ] then "" else lib.head primaries;
    }

    {
      /*
        THE FAN-OUT. Every feature's user packages arrive in my.packages.perUser
        already keyed by account, so this is a rename rather than a decision --
        which is the point: the choice of who gets what was made by each
        feature's own `users` option, and there is exactly one place where it
        becomes a NixOS user.
      */
      users.users = lib.mkMerge [
        (lib.mapAttrs (
          username: u:
          {
            isNormalUser = true;
            inherit (u) extraGroups description;
          }
          // lib.optionalAttrs (u.uid != null) { inherit (u) uid; }
          // lib.optionalAttrs (u.hashedPasswordFile != null) { inherit (u) hashedPasswordFile; }
          // lib.optionalAttrs (u.shell != null) { inherit (u) shell; }
        ) cfg)

        (lib.mapAttrs (_: ps: { packages = ps; }) config.my.packages.perUser)
      ];
    }

    {
      assertions = [
        {
          assertion = cfg == { } || lib.length primaries == 1;
          message =
            "exactly one my.users.<name>.primary must be true, found "
            + (if primaries == [ ] then "none" else lib.concatStringsSep ", " primaries)
            + ". It is what my.<feature>.users defaults to, so it cannot be ambiguous.";
        }

        /*
          Not a style preference: with mutableUsers = false the declared set is
          the whole truth, and `passwd` cannot repair an account afterwards. An
          account with no hashedPasswordFile becomes unloginnable at the first
          switch, and if it is the only sudo-capable one the machine is lost.
        */
        {
          assertion =
            config.users.mutableUsers
            || lib.all (u: u.hashedPasswordFile != null) (lib.attrValues cfg);
          message =
            "users.mutableUsers = false requires a hashedPasswordFile on every my.users entry; missing on: "
            + lib.concatStringsSep ", " (
              lib.attrNames (lib.filterAttrs (_: u: u.hashedPasswordFile == null) cfg)
            );
        }

        /*
          my.packages.perUser is keyed by account name, and every key should
          have come from some feature's `users` option -- which the enum type
          already constrains to declared accounts. A key that is NOT an account
          therefore means someone wrote to perUser directly, and those packages
          would otherwise declare a NixOS user by side effect: exactly the stray
          `r0k0r` this feature exists to prevent.
        */
        {
          assertion = lib.all (n: cfg ? ${n}) (lib.attrNames config.my.packages.perUser);
          message =
            "my.packages.perUser targets accounts not declared in my.users: "
            + lib.concatStringsSep ", " (
              lib.filter (n: !(cfg ? ${n})) (lib.attrNames config.my.packages.perUser)
            )
            + ". Packages must never be the thing that creates a user.";
        }
      ];
    }
  ];
}
