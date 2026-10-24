/*
  my.luks -- full-disk encryption, unlocked by the TPM2 at boot, NO PIN.

  WHAT THIS PROTECTS, AND WHAT IT DOES NOT. No PIN is the user's explicit
  choice, and it follows from the threat model (docs/multiuser-design.md,
  "Threat model": physical access is out of scope). With no PIN the TPM hands
  the key to whatever boots in a state matching the policy below, so:
    - protected: the disk away from this machine -- stolen, sold, RMA'd,
      pulled and read elsewhere. The key is sealed by this machine's TPM and
      is useless without it.
    - not protected: someone holding the whole laptop. On galaxybook4-pro360
      Secure Boot is DISABLED (bootctl status, 2026-10-24), so PCR 7 reads the
      same for any OS booted from USB, and that OS can ask the TPM to unseal.
  That is the accepted trade, written down so nobody mistakes this for
  protection against an evil maid.

  PCR POLICY: [ 7 ] by default ("secure-boot-policy" in systemd-cryptenroll(1)
  -- Secure Boot on/off and the PK, KEK, db, dbx variables). The alternatives
  and why they are not the default:
    - 0 (firmware code) and 2 (option ROMs): change on every firmware update
      or with pluggable hardware; systemd-cryptenroll(1) itself advises
      against them because PCR 7's certificates already cover that code.
    - 4 (boot loader and the PE binaries it starts): would stop a foreign OS
      from unsealing, but changes whenever systemd-boot or the booted kernel
      image changes -- on NixOS that is every kernel update, so every such
      generation would fall back to the recovery key until re-enrolled.
      Under the no-physical-access threat model that buys nothing.
    - 11/12 (UKI and command line, via systemd-stub): need unified kernel
      images and a signed policy (lanzaboote-style); not set up here.
  PCR 7 still CHANGES, and then the TPM refuses and the boot asks for the
  passphrase or recovery key: enabling or disabling Secure Boot, and any
  db/dbx update -- which Windows Update can push on a dual-boot machine like
  this one. After such a boot, re-enroll: `sudo luks-tpm2-enroll` (below).

  The PCRs live in the LUKS2 token header, written at enrollment; crypttab
  only says `tpm2-device=auto`. So `tpm2.pcrs` here is used by the enrollment
  helper only, and changing it does nothing until that is re-run. Note that
  systemd-cryptenroll's own default with no --tpm2-pcrs is NO PCRs at all
  (systemd 261 man page), which would unseal in any boot state -- one more
  reason the helper exists rather than a remembered command line.

  RECOVERY KEY. Enroll one (`systemd-cryptenroll --recovery-key <device>`)
  right after the TPM2 slot, write it down, store it OFFLINE (paper, or a
  password manager on another device) -- never in this repo, never in
  /persist, never anywhere on the disk it unlocks. Test it with
  `cryptsetup open --test-passphrase <device>` before relying on it. Also
  back up the LUKS header offline (`cryptsetup luksHeaderBackup`): a damaged
  header with no backup loses the whole disk, and the backup plus any
  keyslot secret decrypts it, so it is as sensitive as the key.

  ORDER IN THE INITRD (systemd stage 1, the NixOS default; impermanence needs
  it too). NixOS writes /etc/crypttab into the initrd from
  boot.initrd.luks.devices, and systemd-cryptsetup@<name>.service opens the
  mapper. The btrfs inside keeps its own filesystem UUID through an in-place
  encryption, so fileSystems."/" can stay /dev/disk/by-uuid/<btrfs uuid>: that
  link now resolves to /dev/mapper/<name> and its .device unit appears only
  after the unlock. impermanence-rollback is ordered after exactly that
  device unit (features/core/impermanence), and sysroot.mount, /nix and
  /persist wait on it too -- so the rollback runs after the unlock with no
  extra ordering here. The assertion below catches the one mistake that
  would break it: pointing a filesystem (or the rollback) at the LUKS
  partition's own UUID, which is crypto_LUKS, not btrfs.

  SWAP. The swapfile on @swap (my.btrfs-layout.swap, my.swapfile.path =
  /swap/swapfile) is inside the encrypted btrfs, so it is encrypted with no
  configuration. zram is RAM. A swap PARTITION would not be: warned below.

  HIBERNATION (not set up on any host, not tested here). Resuming from a
  swapfile on an encrypted btrfs works in principle: the image is written
  inside the LUKS volume, and the initrd has to unlock it before resuming.
  But with TPM2 and no PIN the hibernation image is exactly as protected as
  the rest of the disk -- the machine unlocks it by itself -- so it adds no
  confidentiality, and a btrfs swapfile needs the resume offset
  (`btrfs inspect-internal map-swapfile -r`) unless systemd's
  HibernateLocation EFI variable supplies it. Treat it as its own task.

  Migration of an existing plaintext btrfs: docs/luks-migration.md.
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.luks;
  imp = config.my.impermanence or { enable = false; };

  devicePath = d: if d.device != null then d.device else "/dev/disk/by-uuid/${d.uuid}";
  luksLinks = lib.concatMap (d: lib.optional (d.uuid != null) "/dev/disk/by-uuid/${d.uuid}") (lib.attrValues cfg.devices);

  pcrArg = lib.concatMapStringsSep "+" toString cfg.tpm2.pcrs;

  /*
    Re-enrollment in one command, from the running system: enroll a fresh
    TPM2 slot bound to `tpm2.pcrs` in the CURRENT boot state, then wipe the
    old TPM2 slots (systemd-cryptenroll enrolls first and wipes after, man
    page --wipe-slot). It asks for the passphrase or recovery key to unlock;
    `--unlock-tpm2-device=auto` would let an old TPM2 slot do that, but after
    a PCR change the old slot is exactly the one that no longer works.
  */
  enroll = pkgs.writeShellScriptBin "luks-tpm2-enroll" ''
    set -eu
    if [ "$(id -u)" != 0 ]; then echo "luks-tpm2-enroll: run as root" >&2; exit 1; fi
    ${lib.concatMapStrings (d: ''
      echo "luks-tpm2-enroll: ${devicePath d} -> PCRs ${pcrArg}"
      ${config.systemd.package}/bin/systemd-cryptenroll ${lib.escapeShellArg (devicePath d)} \
        --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=${pcrArg}
    '') (lib.attrValues cfg.devices)}
  '';
in
{
  options.my.luks = {
    enable = lib.mkEnableOption ''
      full-disk encryption (LUKS2) unlocked by the TPM2 in the systemd initrd,
      with no PIN; a passphrase or recovery key is asked when the TPM refuses.
      Needs the disk encrypted first (docs/luks-migration.md)'';

    devices = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            uuid = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "af35f49a-284f-481a-9e62-22e151185420";
              description = ''
                UUID of the LUKS2 HEADER (`cryptsetup luksUUID <partition>`),
                not of the filesystem inside it. The device opened is
                /dev/disk/by-uuid/<uuid>.
              '';
            };
            device = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "/dev/disk/by-partuuid/3a9a9101-2ac1-448e-ae3f-9d2d323c60b6";
              description = "Explicit device path, instead of `uuid`.";
            };
            allowDiscards = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                crypttab `discard`: pass TRIM through dm-crypt. On (the btrfs
                here mounts with discard=async, which does nothing without
                it). The cost: an observer of the raw disk can tell used
                blocks from free ones -- size and layout, not contents.
              '';
            };
            extraOptions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "tpm2-measure-pcr=yes" ];
              description = "Further crypttab(5) options for this device.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''{ cryptroot.uuid = "<luksUUID>"; }'';
      description = "LUKS devices by mapper name (/dev/mapper/<name>).";
    };

    tpm2 = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Unlock with the TPM2 (crypttab tpm2-device=auto). Off: passphrase only.";
      };
      pcrs = lib.mkOption {
        type = lib.types.nonEmptyListOf (lib.types.ints.between 0 23);
        default = [ 7 ];
        description = ''
          PCRs the TPM2 slot is bound to, used by `luks-tpm2-enroll` (the
          policy itself is stored in the LUKS header at enrollment, so a
          change here needs a re-enroll). See this file's header for why 7.
        '';
      };
    };
  };

  config = lib.mkMerge [
    # Declared unconditionally so features/_meta can see it while it is off.
    # No requires: it works on any filesystem and with or without
    # btrfs-layout or impermanence.
    { my.internal.features.luks.enabledBy = cfg.enable; }

    (lib.mkIf cfg.enable {
      assertions =
        [
          {
            assertion = cfg.devices != { };
            message = "my.luks.enable needs at least one my.luks.devices.<name>.";
          }
          {
            assertion = config.boot.initrd.systemd.enable;
            message = "my.luks: TPM2 unlock via crypttab is systemd-cryptsetup's; set boot.initrd.systemd.enable.";
          }
          {
            assertion = !cfg.tpm2.enable || config.boot.initrd.systemd.tpm2.enable;
            message = "my.luks.tpm2 needs boot.initrd.systemd.tpm2.enable (the TPM2 token plugin and tpm-crb/tpm-tis in the initrd).";
          }
          {
            # The commonest mistake after an in-place encryption: the LUKS
            # partition's UUID is crypto_LUKS, not the btrfs.
            assertion = lib.all (fs: !(lib.elem (fs.device or "") luksLinks)) (lib.attrValues config.fileSystems)
              && !(imp.enable && lib.elem imp.root.btrfs.device luksLinks);
            message = ''
              my.luks: a filesystem (or my.impermanence.root.btrfs.device) points at a LUKS header's
              by-uuid link ${toString luksLinks}. Point it at the filesystem inside: its own by-uuid
              link, or /dev/mapper/<name>.'';
          }
        ]
        ++ lib.mapAttrsToList (n: d: {
          assertion = (d.uuid != null) != (d.device != null);
          message = "my.luks.devices.${n}: set exactly one of uuid and device.";
        }) cfg.devices;

      warnings =
        lib.optional (config.boot.plymouth.enable && config.boot.plymouth.theme == "bonfire")
          "my.luks: the bonfire plymouth theme has no password dialog; when the TPM refuses, press Esc to reach the passphrase prompt."
        ++ map (s: "my.luks: swap device ${s.device} is not inside the encrypted volume (randomEncryption is off).") (
          lib.filter (s: lib.hasPrefix "/dev/" s.device && !(s.randomEncryption.enable or false)) config.swapDevices
        );

      boot.initrd.luks.devices = lib.mapAttrs (_: d: {
        device = devicePath d;
        inherit (d) allowDiscards;
        crypttabExtraOpts = lib.optional cfg.tpm2.enable "tpm2-device=auto" ++ d.extraOptions;
      }) cfg.devices;

      environment.systemPackages = lib.optional cfg.tpm2.enable enroll;
    })
  ];
}
