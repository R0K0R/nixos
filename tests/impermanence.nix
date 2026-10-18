/*
  features/core/impermanence on a synthetic galaxybook4-pro360 laid out as
  planned (docs/impermanence-migration.md): @root rolled back to @root-blank,
  @nix, @persist, @swap, @windows-backup; r0k0r with home = "impermanent".
  Evaluation only -- nothing is rolled back, mounted or booted. Run:
  tests/impermanence-eval.sh. `refused.*` must fail.
*/
{ lib, mkHostWith, mkHomeLib }:

let
  host = "galaxybook4-pro360";

  extendWith =
    { fact ? true, home ? "impermanent" }:
    raw:
    raw
    // {
      users = raw.users // {
        r0k0r = raw.users.r0k0r // {
          overrides = (raw.users.r0k0r.overrides or { }) // { inherit home; };
          # persistent -> impermanent is a type transition (type-record.nix).
          acceptTypeChange = "admin->admin";
        };
      };
      hosts = raw.hosts // {
        features = raw.hosts.features // {
          ${host} = raw.hosts.features.${host} // { impermanence = fact; };
        };
      };
    };

  layout = {
    my.btrfs-layout = {
      enable = true;
      nixSubvolume = "@nix";
      rootSubvolume = "@root";
      persist.enable = true;
      swap.enable = true;
      extraMounts."/home/r0k0r/Backups/windows".subvolume = "@windows-backup";
    };
    my.swapfile.path = "/swap/swapfile";
  };

  hostWith =
    { fact ? true, home ? "impermanent", imp ? true, extra ? { } }:
    mkHostWith {
      hostName = host;
      extraModules = [
        { my.registry.extend = extendWith { inherit fact home; }; }
        layout
        { my.impermanence.enable = imp; }
        extra
      ];
    };

  on = hostWith { };
  c = on.config;
  hl = mkHomeLib host on;
  home = hl.mkHome {
    username = "r0k0r";
    modules = [ { my.persist.directories = [ "KSA" ".ssh" ]; } ];
  };

  expect =
    what: cond: seen:
    if cond then seen else throw "impermanence: ${what}: got ${seen}";
  failing = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.config.assertions);
  refusedBy = what: frag: cfg: expect what (lib.any (lib.hasInfix frag) (failing cfg)) "refused";
  mustFail =
    what: v:
    let
      r = builtins.tryEval (builtins.deepSeq v v);
    in
    if r.success then throw "impermanence: ${what} was accepted, should have been refused" else "refused";

  initrd = c.boot.initrd.systemd.services.impermanence-rollback;
  persistence = c.environment.persistence."/persist";
  dirsOf = map (d: d.directory or d) persistence.directories;
  filesOf = map (f: f.file or f) persistence.files;
in
{
  toplevel = c.system.build.toplevel.drvPath;

  layout = expect "/ from @root, /persist neededForBoot, /swap, the windows backup" (
    lib.elem "subvol=@root" c.fileSystems."/".options
    && c.fileSystems."/persist".neededForBoot
    && lib.elem "subvol=@swap" c.fileSystems."/swap".options
    && c.fileSystems ? "/home/r0k0r/Backups/windows"
    && lib.any (s: s.device == "/swap/swapfile") c.swapDevices
  ) (toString c.fileSystems."/".options);

  rollback = expect "initrd rollback before sysroot.mount, @root <- @root-blank, 14 days kept" (
    lib.elem "sysroot.mount" initrd.before
    && initrd.environment.ROOT == "@root"
    && initrd.environment.BLANK == "@root-blank"
    && initrd.environment.KEEP == "14"
  ) (builtins.toJSON initrd.environment);

  systemPersist = expect "defaults + the agenix identity, declared by the agenix feature itself" (
    lib.elem "/var/lib/nixos" dirsOf && lib.elem "/etc/machine-id" filesOf && lib.elem "/etc/agenix/identity-ed25519" filesOf
  ) (toString filesOf);

  userUnits = expect "persist-home-r0k0r before logins, then hm-reactivate as r0k0r" (
    let
      s = c.systemd.services;
    in
    lib.elem "systemd-user-sessions.service" s.persist-home-r0k0r.before
    && lib.hasInfix "lists" s.persist-home-r0k0r.serviceConfig.ExecStart
    && s.hm-reactivate-r0k0r.serviceConfig.User == "r0k0r"
  ) "ok";

  impermanentFlag = expect "registry home = impermanent -> my.users.r0k0r.impermanentHome" c.my.users.r0k0r.impermanentHome "true";

  homeManifest = expect "the home writes its list for the next boot" (
    lib.hasInfix "/persist/home/r0k0r/.persist.json" home.config.home.activation.persistManifest.data
  ) home.config.home.activation.persistManifest.data;

  refused = {
    noLayout = refusedBy "impermanence without @root/@persist" "needs my.btrfs-layout.rootSubvolume" (
      hostWith { extra.my.btrfs-layout.rootSubvolume = lib.mkForce null; }
    );
    factMismatch = refusedBy "impermanence on, registry fact off" "features.${host}.impermanence" (
      hostWith { fact = false; home = "persistent"; }
    );
    identityLost = refusedBy "agenix identity on the ephemeral root (secret class not persisted)" "age.identityPaths" (
      hostWith { extra.my.impermanence.classes = lib.mkForce [ "state" ]; }
    );
    swapOnRoot = refusedBy "swapfile on the ephemeral root" "swapfile" (hostWith { extra.my.swapfile.path = lib.mkForce "/swapfile"; });
    noFact = mustFail "home = impermanent on a host without the fact" (
      lib.attrNames (hostWith { fact = false; imp = false; }).config.my.users
    );
    emptyList = mustFail "an impermanent home with an empty my.persist" (hl.mkHome { username = "r0k0r"; }).activationPackage.drvPath;
  };
}
