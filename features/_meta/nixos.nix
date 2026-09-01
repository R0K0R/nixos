{ config, lib, ... }:

let
  decl = config.my.internal.features;

  present = name: decl ? ${name};
  enabled = name: present name && decl.${name}.enabledBy;

  requirements = lib.concatLists (
    lib.mapAttrsToList (
      name: f:
      map (r: { inherit name r; enabledBy = f.enabledBy; }) f.requires
    ) decl
  );

  /*
    Role -> the enabled features claiming it. Built by folding rather than by
    mapAttrs so a role can collect claimants from features that know nothing
    about each other, which is the whole point of naming a role instead of
    naming rivals.
  */
  roleClaims = lib.foldl' (
    acc: name:
    let
      f = decl.${name};
    in
    if !f.enabledBy then
      acc
    else
      lib.foldl' (a: role: a // { ${role} = (a.${role} or [ ]) ++ [ name ]; }) acc f.provides
  ) { } (lib.attrNames decl);
in
{
  /*
    Feature dependencies, declared as data and enforced as assertions.

    Two failure modes need distinguishing, and only one of them was already
    caught. A missing feature DIRECTORY fails at evaluation on its own, but with
    a useless message -- `error: attribute 'compositor' missing`, from wherever
    the option happened to be read. A feature that is present but NOT ENABLED
    fails at nothing: it evaluates cleanly, builds, switches, and leaves you with
    a broken machine.

    That second kind is what produced the greeter crash loop documented in
    features/hyprland/nixos.nix -- `programs.hyprland.withUWSM` unset meant the
    systemd user units uwsm needs were never generated, and the greeter died with
    "systemctl --user start ... exit status 5" on every login attempt. Nothing in
    the config was wrong enough to fail a build.

    ASSERT, NEVER AUTO-ENABLE. A feature that silently switches on three others
    makes the host file stop describing the machine, which is the property this
    whole layout exists to provide. The assertion names the exact line to add.

    A feature with no dependencies never touches this option, which is what keeps
    it standalone: features/samsung-galaxybook/ can be handed to someone who does
    not have this file.
  */
  options.my.internal.features = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          requires = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Other features that must be enabled alongside this one.";
          };
          enabledBy = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "This feature's own enable flag, so the assertion only fires when it is on.";
          };

          provides = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "shell" ];
            description = ''
              Roles this feature fills. At most one ENABLED feature may fill a
              given role; the assertion below names every claimant when two do.

              A ROLE, NOT A LIST OF RIVALS. The obvious alternative is a
              pairwise `conflicts = [ "waybar" ]`, and it was rejected because
              it does not scale in the direction this repo grows: adding a
              third shell means editing the two that already exist, and
              forgetting one half leaves a conflict that is declared in one
              direction only. Naming the role instead means a new shell
              declares `provides = [ "shell" ]` and is mutually exclusive with
              everything else claiming it, with no edit anywhere else.

              It also says something true about the feature on its own, which
              `conflicts` does not: a feature listing rivals is only meaningful
              relative to a particular set of siblings, so it stops being
              giftable the moment it names one that the recipient does not
              have.

              The role is the interface, so the name should describe what the
              slot IS -- "shell", "compositor", "greeter" -- not what happens
              to occupy it.
            '';
          };
        };
      }
    );
    default = { };
    description = ''
      Feature dependency graph. Introspectable:
        nix eval .#nixosConfigurations.<host>.config.my.internal.features --json
    '';
  };

  config.assertions =
    map (req: {
      assertion = !req.enabledBy || enabled req.r;
      message =
        if !(present req.r) then
          "feature '${req.name}' requires '${req.r}', which is not present in features/"
        else
          "my.${req.name}.enable requires my.${req.r}.enable";
    }) requirements

    /*
      One claimant per role. Unlike a missing dependency, a DOUBLE claim does
      not fail at evaluation on its own -- two shells both configure the
      compositor, both start their own bar, and the result is a session with
      two of everything and no error anywhere. Exactly the silent-breakage
      class the requires assertions exist for, in the opposite direction.
    */
    ++ lib.mapAttrsToList (role: claimants: {
      assertion = lib.length claimants <= 1;
      message =
        "at most one feature may provide the '${role}' role, but these are all enabled: "
        + lib.concatStringsSep ", " claimants
        + ". Disable all but one.";
    }) roleClaims;
}
