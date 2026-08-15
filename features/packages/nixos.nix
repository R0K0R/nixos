{ config, lib, ... }:

let
  cfg = config.my.packages;

  pnameOf = p: p.pname or p.name or "?";

  /*
    Report genuine collisions: the same pname appearing as two DIFFERENT
    derivations in one environment.

    Worth surfacing because it is silent where it matters most.
    environment.systemPackages and users.users.<n>.packages both go through
    buildEnv with ignoreCollisions = true (system-path.nix:211;
    users-groups.nix:995 inherits it), so the winner is whichever comes first in
    list order -- decided by module import order -- with nothing but a build-log
    warning. Only home.packages hard-errors.

    The live case is victus-15's `btop.override { cudaSupport = true; }` against
    a plain btop from a feature: both are "btop", one has CUDA, and which one
    lands on PATH was previously a matter of import order.

    Scoped to pnames that my.packages.extra actually contributes. An unscoped
    duplicate-pname check fires on NixOS's own baseline -- fuse, glibc, polkit
    and shadow all appear twice in a stock systemPackages as wrapped and
    unwrapped variants -- which is real but not this feature's business, and
    reporting it on every evaluation is noise that trains you to ignore the
    warning that matters.
  */
  collisionsIn =
    extra: packages:
    let
      extraNames = lib.unique (map pnameOf extra);
      byName = lib.groupBy pnameOf packages;
      conflicting = lib.filterAttrs (
        n: ps: builtins.elem n extraNames && lib.length (lib.unique (map (p: p.outPath) ps)) > 1
      ) byName;
    in
    lib.attrNames conflicting;

  literalNote = target: ''
    Host-specific additions to ${target}, for one-offs that do not justify a
    feature of their own.

    MUST BE A LITERAL LIST -- no mkIf, no mkMerge, no reference to `config`.
    tuning/runtime-cache/lookup.nix reads this attrset out of the host file by
    RAW IMPORT, without a module evaluation, so it cannot resolve a property
    list. Wrapping a leaf fails loudly; wrapping the parent used to return an
    empty anchor set silently, which is why lookup.nix now rejects anything
    carrying a `_type`.
  '';
in
{
  options.my.packages.extra = {
    system = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = literalNote "environment.systemPackages";
    };

    user = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = literalNote "users.users.r0k0r.packages";
    };

    home = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = literalNote "home.packages";
    };
  };

  config = lib.mkMerge [
    # mkOrder 100 places these BEFORE feature packages, so under buildEnv's
    # first-wins the host's version is the one that lands on PATH. Deterministic,
    # rather than depending on module import order.
    (lib.mkIf (cfg.extra.system != [ ]) {
      environment.systemPackages = lib.mkOrder 100 cfg.extra.system;
    })

    (lib.mkIf (cfg.extra.user != [ ]) {
      users.users.r0k0r.packages = lib.mkOrder 100 cfg.extra.user;
    })

    {
      warnings =
        let
          hits = collisionsIn cfg.extra.system config.environment.systemPackages;
        in
        lib.optional (hits != [ ]) ''
          environment.systemPackages contains the same pname as two different
          derivations: ${lib.concatStringsSep ", " hits}.

          buildEnv resolves this silently by list order (ignoreCollisions =
          true), so only one is reachable on PATH. my.packages.extra is ordered
          first and therefore wins. If that is not what you meant, drop the
          entry or turn the difference into an option on the owning feature.
        '';
    }
  ];
}
