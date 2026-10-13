{ lib, pkgs, config, osConfig, inputs, ... }:

let
  hearth = inputs.hearth.packages.${pkgs.system}.default;

  # Assemble the schema from every feature's own `hearth.nix` fragment (each a flat attrset of setting
  # records keyed by dotted path, or a function taking { lib }). This mirrors the flake's feature
  # auto-discovery: a feature owns its slice, `rm -r features/<x>` takes its settings too. The file is
  # named `hearth.nix` (NOT settings.nix) deliberately -- `settings.nix` already means other things in
  # some features (e.g. features/dms is DankMaterialShell's own config). A NEW hearth.nix must be
  # `git add`ed to be visible to flake eval (the flake source is the git tree).
  featuresDir = ../.;
  featureNames = builtins.attrNames (builtins.readDir featuresDir);
  fragmentPaths = builtins.filter builtins.pathExists
    (map (n: featuresDir + "/${n}/hearth.nix") featureNames);
  loadFragment = p: let v = import p; in if builtins.isFunction v then v { inherit lib; } else v;
  merged = lib.foldl' (acc: p: acc // (loadFragment p)) { } fragmentPaths;

  schema = { settings = merged; };
  schemaFile = pkgs.writeText "bonfire-settings-schema.json" (builtins.toJSON schema);
  stateDir = "${config.home.homeDirectory}/.local/state/hearth";
in
{
  config = lib.mkIf (osConfig.my.settings.enable or false) {
    home.packages = [ hearth ];

    # The generated schema is a read-only INPUT for hearth; hearth writes overrides.json /
    # settings.json / settings.signal.json beside it at runtime (those stay HM-unmanaged).
    home.file.".local/state/hearth/schema.json".source = schemaFile;

    # Materialise settings.json from the (possibly new) schema defaults ⊕ the user's persisted
    # overrides on every activation (i.e. every rebuild). This also emits the change signal, so a
    # rebuild that shifts a default live-updates any running consumer. Runs after the schema symlink
    # is in place.
    home.activation.hearthSync = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      export HEARTH_DIR="${stateDir}"
      run ${hearth}/bin/hearth sync > /dev/null 2>&1 || true
    '';
  };
}
