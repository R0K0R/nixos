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
        };
      }
    );
    default = { };
    description = ''
      Feature dependency graph. Introspectable:
        nix eval .#nixosConfigurations.<host>.config.my.internal.features --json
    '';
  };

  config.assertions = map (req: {
    assertion = !req.enabledBy || enabled req.r;
    message =
      if !(present req.r) then
        "feature '${req.name}' requires '${req.r}', which is not present in features/"
      else
        "my.${req.name}.enable requires my.${req.r}.enable";
  }) requirements;
}
