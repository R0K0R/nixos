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
        # The committed host narrows r0k0r to impermanent itself (since the
        # migration); a persistent variant has to drop that too.
        hosts = raw.hosts.hosts // {
          ${host} = raw.hosts.hosts.${host} // {
            narrow = (raw.hosts.hosts.${host}.narrow or { }) // {
              r0k0r = builtins.removeAttrs (raw.hosts.hosts.${host}.narrow.r0k0r or { }) [ "home" ];
            };
          };
        };
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

  # What persist-home-r0k0r is handed: the writeText of {directories, files}. The
  # test cannot read that derivation (pure evaluation), so it rebuilds the same
  # one from the declared my.state.user classes and requires the unit to name it.
  stateUser = c.my.state.user;
  pickUser = kind: lib.unique (lib.concatMap (cl: stateUser.${cl}.${kind} or [ ]) [ "secret" "state" ]);
  expectedUserData = on.pkgs.writeText "impermanence-user-state.json" (
    builtins.toJSON {
      directories = [ ".local/state/nix" ".local/state/home-manager" ] ++ pickUser "directories";
      files = pickUser "files";
    }
  );
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

  # Declared by the features themselves: system paths reach environment.persistence,
  # user paths reach the userData JSON that persist-home-<user> reads.
  # waydroid is "state" since c5df030 (its images and data), flatpak since
  # dad7e9d (system-wide installs, Sober); doom is "optional", which the
  # default classes leave out. .ssh is not here any more: ssh is a home
  # feature since 2026-10-26, and the home's my.persist declares it.
  featureState = expect "fprint, cups, AccountsService, waydroid, flatpak reach /persist; firefox, DMS, Claude Code reach the persist-home's user data; optional doom does not" (
    lib.all (d: lib.elem d dirsOf) [ "/var/lib/fprint" "/var/lib/cups" "/var/lib/AccountsService" "/var/lib/waydroid" "/var/lib/flatpak" ]
    && lib.all (p: lib.elem p (pickUser "directories")) [ ".mozilla/firefox" ".local/state/DankMaterialShell" ]
    && lib.all (p: lib.elem p (pickUser "files")) [ ".claude.json" ]
    && !(lib.elem ".local/share/doom" (pickUser "directories"))
    && lib.hasInfix (builtins.unsafeDiscardStringContext (toString expectedUserData)) c.systemd.services.persist-home-r0k0r.serviceConfig.ExecStart
  ) (toString dirsOf);

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
    # The agenix feature reads its identities from the persist root since
    # c5df030, so only an identity path set past it can land on the root.
    identityLost = refusedBy "agenix identity on the ephemeral root" "age.identityPaths" (
      hostWith { extra.age.identityPaths = lib.mkForce [ "/etc/agenix/elsewhere" ]; }
    );
    swapOnRoot = refusedBy "swapfile on the ephemeral root" "swapfile" (hostWith { extra.my.swapfile.path = lib.mkForce "/swapfile"; });
    noFact = mustFail "home = impermanent on a host without the fact" (
      lib.attrNames (hostWith { fact = false; imp = false; }).config.my.users
    );
    emptyList = mustFail "an impermanent home with an empty my.persist" (hl.mkHome { username = "r0k0r"; }).activationPackage.drvPath;
  };
}
