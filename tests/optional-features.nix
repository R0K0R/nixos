/*
  The optional pieces as a dependency graph (docs/multiuser-design.md,
  "Everything optional"): each one is its own feature in features/_meta's
  my.internal.features, and its requirements fire as assertions with a
  message naming the missing switch.

  Plus features/core/luks on galaxybook4-pro360 as it will be after
  docs/luks-migration.md (hosts/galaxybook4-pro360/luks.nix). Evaluation
  only -- nothing is encrypted, enrolled or booted. `refused.*` must fail.
  Run: tests/optional-features-eval.sh.
*/
{ lib, mkHostWith }:

let
  gb4 = "galaxybook4-pro360";

  hostWith =
    extra:
    mkHostWith {
      hostName = gb4;
      extraModules = [ extra ];
    };
  luksOn = hostWith ../hosts/galaxybook4-pro360/luks.nix;
  c = luksOn.config;

  expect =
    what: cond: seen:
    if cond then seen else throw "optional-features: ${what}: got ${seen}";
  failing = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.config.assertions);
  refusedBy = what: frag: cfg: expect what (lib.any (lib.hasInfix frag) (failing cfg)) (builtins.toJSON (failing cfg));

  pieces = [ "btrfs-layout" "impermanence" "guest-overlay" "ccache" "ccache.builder" "ca-derivations" "luks" ];
  graphOf = cfg: lib.genAttrs pieces (p: cfg.config.my.internal.features.${p}.requires);
  graph = graphOf luksOn;

  rollback = c.boot.initrd.systemd.services.impermanence-rollback;
  btrfsUnit = "dev-disk-by\\x2duuid-473402c5\\x2dfb75\\x2d4760\\x2dafee\\x2de10d2da78f5b.device";
in
{
  toplevel = c.system.build.toplevel.drvPath;

  # The requires edges, exactly: impermanence and guest-overlay need
  # btrfs-layout, nothing else needs anything.
  graph = expect "requires graph" (
    graph == {
      btrfs-layout = [ ];
      impermanence = [ "btrfs-layout" ];
      guest-overlay = [ "btrfs-layout" ];
      ccache = [ ];
      "ccache.builder" = [ ];
      ca-derivations = [ ];
      luks = [ ];
    }
  ) (builtins.toJSON graph);

  luksCrypttab = expect "cryptroot by LUKS uuid, discard, tpm2-device=auto" (
    let
      d = c.boot.initrd.luks.devices.cryptroot;
    in
    d.device == "/dev/disk/by-uuid/af35f49a-284f-481a-9e62-22e151185420"
    && d.allowDiscards
    && d.crypttabExtraOpts == [ "tpm2-device=auto" ]
    && c.boot.initrd.systemd.enable
    && c.boot.initrd.systemd.tpm2.enable
  ) (builtins.toJSON c.boot.initrd.luks.devices.cryptroot.crypttabExtraOpts);

  # The rollback waits on the btrfs's own device unit, which appears only once
  # the mapper is open -- unchanged by luks, and not the LUKS partition.
  rollbackAfterUnlock = expect "rollback after the btrfs device, before sysroot" (
    lib.elem btrfsUnit rollback.after && lib.elem btrfsUnit rollback.requires && lib.elem "sysroot.mount" rollback.before
  ) (toString rollback.after);

  enrollHelper = expect "luks-tpm2-enroll binds PCR 7 and wipes old tpm2 slots" (
    let
      p = lib.findFirst (p: (p.name or "") == "luks-tpm2-enroll") null c.environment.systemPackages;
    in
    p != null && lib.hasInfix "--wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7" p.text
  ) "ok";

  refused = {
    impermanenceWithoutLayout = refusedBy "impermanence without btrfs-layout" "my.impermanence.enable requires my.btrfs-layout.enable" (
      hostWith { my.btrfs-layout.enable = lib.mkForce false; }
    );
    luksNoDevices = refusedBy "luks with no device" "at least one my.luks.devices" (hostWith { my.luks.enable = true; });
    luksUuidOnFs = refusedBy "a filesystem pointed at the LUKS header" "points at a LUKS header" (
      hostWith {
        imports = [ ../hosts/galaxybook4-pro360/luks.nix ];
        fileSystems."/".device = lib.mkForce "/dev/disk/by-uuid/af35f49a-284f-481a-9e62-22e151185420";
      }
    );
    luksScriptedInitrd = refusedBy "luks without the systemd initrd" "boot.initrd.systemd.enable" (
      hostWith {
        imports = [ ../hosts/galaxybook4-pro360/luks.nix ];
        boot.initrd.systemd.enable = lib.mkForce false;
      }
    );
    luksBothUuidAndDevice = refusedBy "uuid and device both set" "exactly one of uuid and device" (
      hostWith {
        imports = [ ../hosts/galaxybook4-pro360/luks.nix ];
        my.luks.devices.cryptroot.device = "/dev/nvme0n1p2";
      }
    );
  };
}
