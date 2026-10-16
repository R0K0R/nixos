/*
  my.users from registry/, for whichever host this is. A module of its own,
  rather than a mkHost-only specialArg, because TWO evaluations need it:
  mkHost and tuning/runtime-cache/tier2-eval.nix's pass1. pass1 seeing no
  accounts is exactly the silent failure lib/home-manager.nix's header
  describes -- no my.users, no home-manager users, every home.packages entry
  drops out of the Tier 2 anchors and gets built untuned. Both import this file,
  so they cannot drift.

  `hostName` is a specialArg both of them already pass.

  my.registry.loaded is the registry THIS evaluation used, so homeLib facts
  (flake.nix mkHomeLib) read the same data the accounts were made from --
  including in a synthetic host whose registry was extended by a test.
*/
{ config, hostName, lib, pkgs, ... }:

let
  reg = config.my.registry.loaded;
  facts = reg.hosts.features.${hostName} or { };
in
{
  options.my.registry = {
    extend = lib.mkOption {
      type = lib.types.functionTo lib.types.raw;
      default = raw: raw;
      internal = true;
      description = ''
        Maps the raw registry ({ users, types, hosts }) before it is checked.
        For tests (tests/user-types.nix): synthetic users on a synthetic
        copy of a host. A real host never sets it -- people belong in
        registry/users/, where every host's checks see them.
      '';
    };

    loaded = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      description = "The validated registry (lib/registry.nix `load`) this host was evaluated with.";
    };
  };

  config = {
    my.registry.loaded = import ../registry {
      inherit lib;
      inherit (config.my.registry) extend;
    };

    my.users = reg.materialize hostName pkgs;

    /*
      registry/hosts.nix features are facts that homeLib reports to users as
      what their builds do (nixFacts). A fact that drifts from the switch is
      worse than no fact, so the two that nixFacts reads are held to the
      config here. Assertions only: nothing in the toplevel moves.
    */
    assertions = [
      {
        assertion = !(facts ? localBuilds) || facts.localBuilds == (config.nix.settings.max-jobs != 0);
        message = ''
          registry/hosts.nix: features.${hostName}.localBuilds = ${lib.boolToString facts.localBuilds or false}
          but nix.settings.max-jobs = ${toString config.nix.settings.max-jobs}. Fix whichever is wrong.'';
      }
      {
        assertion = !(facts ? builderClient) || facts.builderClient == config.nix.distributedBuilds;
        message = ''
          registry/hosts.nix: features.${hostName}.builderClient = ${lib.boolToString facts.builderClient or false}
          but nix.distributedBuilds = ${lib.boolToString config.nix.distributedBuilds}.'';
      }
    ];
  };
}
