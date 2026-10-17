{ lib, pkgs, config, userInputs, ... }:

let
  cfg = config.my.settings;
  hearth = userInputs.hearth.packages.${pkgs.stdenv.hostPlatform.system}.default;

  /*
    Assemble the schema from the fragments the other modules contribute through
    my.settings.fragments (each a flat attrset of setting records keyed by
    dotted path, or a function taking { lib }).

    This used to be a readDir walk over features/<name>/hearth.nix, mirroring the
    system flake's feature auto-discovery. A user repo has no such directory
    convention and a walk would silently miss a fragment that lives next to its
    module, so the fragments are now REGISTERED: a module that owns a slice of
    the schema adds `my.settings.fragments = [ (import ./hearth.nix) ]` beside
    the rest of its config, and removing the module removes its settings with
    it, exactly as `rm -r features/<x>` did.
  */
  loadFragment = v: if builtins.isFunction v then v { inherit lib; } else v;
  merged = lib.foldl' (acc: v: acc // (loadFragment v)) { } cfg.fragments;

  schema = { settings = merged; };
  schemaFile = pkgs.writeText "bonfire-settings-schema.json" (builtins.toJSON schema);
  stateDir = "${config.home.homeDirectory}/.local/state/hearth";
in
{
  options.my.settings = {
    enable = lib.mkEnableOption
      "the unified hearth settings store (generated schema.json + runtime settings.json + change signal)";

    fragments = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [ ];
      description = ''
        Schema fragments, one per module that owns settings. Each is an attrset
        of hearth setting records keyed by dotted path, or a function of
        `{ lib }` returning one. Merged in list order; a later fragment wins on
        a duplicate key. See SETTINGS.md for the record format.
      '';
    };
  };

  # The unified settings system: the hearth engine (generic store + change-diff signal) fed by a
  # schema assembled from the fragments. See SETTINGS.md for the design.
  config = lib.mkIf cfg.enable {
    home.packages = [ hearth ];

    # The generated schema is a read-only INPUT for hearth; hearth writes overrides.json /
    # settings.json / settings.signal.json beside it at runtime (those stay HM-unmanaged).
    home.file.".local/state/hearth/schema.json".source = schemaFile;

    # Materialise settings.json from the (possibly new) schema defaults + the user's persisted
    # overrides on every activation (i.e. every switch). This also emits the change signal, so a
    # switch that shifts a default live-updates any running consumer. Runs after the schema symlink
    # is in place.
    home.activation.hearthSync = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      export HEARTH_DIR="${stateDir}"
      run ${hearth}/bin/hearth sync > /dev/null 2>&1 || true
    '';
  };
}
