/*
  galaxybook4-pro360 AFTER the LUKS migration (docs/luks-migration.md).
  NOT imported by default.nix: until the live-USB session the btrfs on
  /dev/nvme0n1p2 is plaintext, and an initrd waiting for a LUKS header there
  would never find one.

  The LUKS UUID is chosen HERE, ahead of time, and handed to
  `cryptsetup reencrypt --encrypt --uuid` on the day (cryptsetup-reencrypt(8):
  "When used in encryption mode, use the provided UUID for the new LUKS header
  instead of generating a new one"). That is what lets
  `migration.galaxybook4-pro360-luks` (flake.nix) be built on victus before
  the session, so the USB only installs a finished system. Generated with
  uuidgen on 2026-10-24; it identifies nothing yet.

  fileSystems stay as they are: an in-place encryption keeps the btrfs (and
  its UUID 473402c5-...) intact inside the mapper, and
  /dev/disk/by-uuid/473402c5-... then resolves to /dev/mapper/cryptroot.

  On the day, committing it is one edit that must reproduce that toplevel
  (check the drvPath): hosts/galaxybook4-pro360/default.nix imports ./luks.nix.
*/
{
  my.luks = {
    enable = true;
    devices.cryptroot.uuid = "af35f49a-284f-481a-9e62-22e151185420";
  };
}
