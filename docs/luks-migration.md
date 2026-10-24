# LUKS migration — galaxybook4-pro360

The runbook for encrypting galaxybook4-pro360's existing btrfs partition in
place, from a live USB, with TPM2 unlock and no PIN (`features/core/luks`).
**Nothing here has been run.** The feature and the post-migration host were
only evaluated (2026-10-24, `tests/optional-features-eval.sh`). If you are a
Claude helping on the day: read this whole file and
`features/core/luks/nixos.nix` before running anything, and do not start
phase 2 until the user has explicitly confirmed that the backup in phase 0
exists and has been checked.

In-place encryption rewrites every block of an 830.9G partition holding the
only copy of this machine's state. A mistake in the shrink step, the wrong
partition, or a failing disk loses data. The backup is the only real undo.

## Where things stand

Read on the running laptop on 2026-10-24 (`lsblk`, `bootctl status`, sysfs).
Check it again on the day; partition numbers are not stable identifiers.

| partition | size | type | what | touch? |
|---|---|---|---|---|
| `nvme0n1p1` | 16M | Microsoft reserved | Windows | **no** |
| `nvme0n1p2` | 830.9G | btrfs `473402c5-fb75-4760-afee-e10d2da78f5b`, PARTUUID `3a9a9101-2ac1-448e-ae3f-9d2d323c60b6`, partlabel `nixos` | NixOS: `@root @nix @persist @swap @windows-backup @root-blank @pre-migration` (+ `old-roots/`) | **this one only** |
| `nvme0n1p3` | 17.4G | NTFS, `SAMSUNG_REC2` | Samsung recovery | **no** |
| `nvme0n1p4` | 1G | vfat `4887-E69E`, `SAMSUNG_REC` | Samsung recovery | **no** |
| `nvme0n1p5` | 1G | vfat `DFF1-0A5E`, `EFI` | NixOS's ESP, mounted at `/boot` (systemd-boot, and the `windows.conf` entry) | mount only, in step 2.9 |
| `nvme0n1p6` | 200M | vfat `BCC9-C2E3`, `EFI system partition` | Windows' ESP | **no** |
| `nvme0n1p7` | 80.7G | NTFS | Windows | **no** |

- Secure Boot is **disabled**, and the TPM is a TPM 2.0 (`bootctl status`: "TPM2 Support: yes").
- The NVMe reports 512-byte logical and physical sectors. The btrfs sectorsize is 4096.
- The root is impermanent (`features/core/impermanence`, live since 2026-10-24). The
  rollback runs in the systemd initrd, after the btrfs device appears.
- Plymouth is off on this host, so the passphrase prompt is visible on the console.

**What the migration changes.** `nvme0n1p2` gets a LUKS2 header at its start.
The same btrfs moves inside the header, shifted, and keeps its UUID
`473402c5-…`. Once the volume is opened, `/dev/disk/by-uuid/473402c5-…`
resolves to `/dev/mapper/cryptroot`, so every `fileSystems` entry and the
impermanence rollback stay as they are. Every subvolume ends up encrypted:
`@swap` (so the swapfile), `@windows-backup`, `@pre-migration` and the old roots.

**What it does not change.** The Windows partitions, both ESPs, the Samsung
recovery partitions, Secure Boot, the TPM's ownership. Do **not** clear the TPM
(in the firmware or with `tpm2_clear`): that would also wipe any Windows
BitLocker TPM protector.

**The code:**
- `features/core/luks/nixos.nix` (`my.luks`): the crypttab entry
  (`tpm2-device=auto`, `discard`), the assertions, and `luks-tpm2-enroll`
- `hosts/galaxybook4-pro360/luks.nix`: the post-migration settings, NOT
  imported. Its LUKS UUID `af35f49a-284f-481a-9e62-22e151185420` was picked in
  advance and is passed to cryptsetup with `--uuid`.
- the flake output `migration.galaxybook4-pro360-luks`: the host with that file
- `tests/optional-features.nix`

**PCR policy:** PCR 7 alone. The reasons and the caveats are in the feature's
header. In short:
- With Secure Boot off, PCR 7 does not stop another OS booted on this laptop
  from unsealing the key. Physical access is out of scope (design doc, "Threat
  model"), so that is accepted. What the TPM binding does protect is the disk
  away from this machine.
- PCR 7 changes when Secure Boot is toggled or when db/dbx are updated, and
  Windows Update can push a dbx update. After such a change, the next boot asks
  for the passphrase or the recovery key. Then run `sudo luks-tpm2-enroll`.

## Phase 0 — backup (the user confirms before phase 2)

1. **Choose what to back up.** Check the sizes first: `sudo btrfs filesystem
   usage /` and `sudo btrfs subvolume list /`.
   - **Essential:** `@persist`, everything that survives a boot.
   - **Keep if possible:** `@windows-backup`.
   - **Optional:**
     - `@pre-migration`: the pre-impermanence tree.
     - `@nix`: rebuildable, but the tuned store is a multi-day rebuild. Most of
       it should also be on victus-15, so check `nix path-info --store
       ssh-ng://victus-15` for the toplevel before counting on that.
   - **Skip:** `@root` and `old-roots/`, which are thrown away at boot anyway,
     and `@root-blank`, which is empty.
2. **Back up to an external disk** formatted btrfs, from read-only snapshots, as root:
   ```
   mount -o subvolid=5 /dev/disk/by-uuid/473402c5-fb75-4760-afee-e10d2da78f5b /mnt/top
   btrfs subvolume snapshot -r /mnt/top/@persist /mnt/top/@persist.luks-backup
   btrfs send /mnt/top/@persist.luks-backup | btrfs receive /media/backup/
   # same for @windows-backup (and the optional ones)
   ```
   Snapshots share extents, and `btrfs send` without `-p` sends each one
   whole. Size the disk from the usage numbers, not from a guess.
3. **Also save, next to the backup:**
   - the partition table: `sfdisk -d /dev/nvme0n1 > gb4-nvme0n1.sfdisk`;
   - the current `lsblk -o NAME,SIZE,FSTYPE,UUID,PARTUUID,PARTLABEL` output.
4. **Check the backup.**
   - Mount it, then open a sample of files.
   - Run `git fsck` in a few repositories under `~/flakes` and `~/git_shit`.
   - Run `git annex fsck` for `~/KSA`, which should also be synced to yulee
     (`git annex sync --content`).
   - Have the agenix identity's seed phrase at hand.
   - If Windows uses BitLocker, have its recovery key too. Nothing here should
     trigger it, but firmware menus are close by.
5. **The user confirms** "backup checked" in so many words. Without that, stop here.

## Phase 1 — prepare (on the running laptop)

1. **Review** `hosts/galaxybook4-pro360/luks.nix`. Then check that the
   post-migration system evaluates:
   `nix eval --raw .#migration.galaxybook4-pro360-luks.config.system.build.toplevel.drvPath`.
2. **Build it** on the builders (max-jobs 0 dispatches it). Keep it alive with
   an out-link in a persisted directory, because `~` itself is wiped:
   ```
   nix build .#migration.galaxybook4-pro360-luks.config.system.build.toplevel \
     --out-link ~/flakes/luks-plan-system
   readlink -f ~/flakes/luks-plan-system      # write this path down: TOPLEVEL
   ```
   It differs from the running system only by the crypttab, the cryptsetup
   units in the initrd, and `luks-tpm2-enroll`.
3. **Check the TPM:** `systemd-cryptenroll --tpm2-device=list` should list one device.
4. **Use a live USB** with a recent NixOS ISO. It must boot with Secure Boot
   off (as now) and have `cryptsetup` and `btrfs-progs`. The ISO's Nix may be
   older than the 2.35 store database in `@nix`, so the install in step 2.9
   uses the system's own Nix through `nixos-enter`, as the impermanence
   migration did.

## Phase 2 — encrypt (on the live USB, as root, on AC power)

Do this offline. Online encryption of a mounted root is not possible here:
`/` cannot be unmounted while it is in use.

```
DEV=/dev/disk/by-partuuid/3a9a9101-2ac1-448e-ae3f-9d2d323c60b6
```

1. **Confirm the device.** Check `lsblk -o NAME,SIZE,FSTYPE,UUID,PARTUUID,PARTLABEL`
   and `blkid $DEV`: it must show `TYPE="btrfs"` and UUID `473402c5-…`. Do not
   mount it except where a step says to.
2. **Check the filesystem:** `btrfs check --readonly $DEV`. If it reports
   errors, stop and do not continue.
3. **Shrink the btrfs.** `cryptsetup reencrypt --reduce-device-size 32m` uses
   the last 32 MiB of the device as temporary space. Of those 32 MiB, half
   becomes the LUKS2 header and the data shifts back by the other half
   (cryptsetup-reencrypt(8), which recommends at least `32M`). Anything the
   filesystem still has there is destroyed. Shrink by more than that, so
   rounding never matters. 1 GiB here is a margin chosen for this runbook, not
   a requirement:
   ```
   mount -o subvolid=5 $DEV /mnt
   btrfs filesystem resize -1G /mnt
   btrfs filesystem show /mnt          # devid 1 size: must be ≥ 32 MiB below the partition
   blockdev --getsize64 $DEV           # the partition, in bytes
   umount /mnt
   ```
4. **Encrypt.** This asks for a new passphrase, which becomes the first
   keyslot. Choose one you can type at a console prompt:
   ```
   cryptsetup reencrypt --encrypt --type luks2 \
     --reduce-device-size 32m --sector-size 512 \
     --uuid af35f49a-284f-481a-9e62-22e151185420 \
     $DEV
   ```
   - **Why `--sector-size 512`:** the man page warns that an encryption sector
     larger than the device's *physical* sector "may result in data corruption
     during unexpected power failures". This NVMe reports 512, so 512 is the
     conservative choice. 4096 would match the btrfs sectorsize and is the
     faster option, at that documented risk. Re-check
     `/sys/block/nvme0n1/queue/physical_block_size` on the day.
   - **Duration:** the whole partition is rewritten. That time was not
     measured; it depends on the disk and the CPU.
   - **Interruptions:**
     - Ctrl-C (SIGINT) and SIGTERM are safe. Resume with
       `cryptsetup reencrypt --resume-only $DEV`.
     - After a crash or a power loss, recovery runs on the next open (or
       `cryptsetup repair $DEV`), then resume.
     - With `--reduce-device-size`, the resilience mode is fixed (datashift).
       Do not try to change it on resume.
5. **Verify:**
   ```
   cryptsetup luksDump $DEV                 # LUKS2, UUID af35f49a-…, one keyslot
   cryptsetup open $DEV cryptroot
   blkid /dev/mapper/cryptroot              # TYPE="btrfs", UUID 473402c5-…
   btrfs check --readonly /dev/mapper/cryptroot
   ```
6. **Grow the btrfs back:**
   `mount -o subvolid=5 /dev/mapper/cryptroot /mnt && btrfs filesystem resize max /mnt && umount /mnt`.
7. **Back up the LUKS header** to the backup disk:
   `cryptsetup luksHeaderBackup $DEV --header-backup-file /media/backup/gb4-luks-header.img`.
   - A damaged header without this backup loses the whole disk.
   - With any keyslot's secret, the backup decrypts the disk, so keep it as
     safe as the key.
8. **Mount the layout** under `/mnt/new`:
   ```
   mkdir -p /mnt/new
   mount -o subvol=@root    /dev/mapper/cryptroot /mnt/new
   mkdir -p /mnt/new/nix /mnt/new/persist /mnt/new/boot   # @root is a fresh copy of the empty @root-blank
   mount -o subvol=@nix     /dev/mapper/cryptroot /mnt/new/nix
   mount -o subvol=@persist /dev/mapper/cryptroot /mnt/new/persist
   mount /dev/disk/by-uuid/DFF1-0A5E /mnt/new/boot  # NixOS's ESP -- NOT BCC9-C2E3 (Windows')
   ```
9. **Install the prepared generation** with the system's own Nix (TOPLEVEL from
   phase 1). This is the same command as `scripts/impermanence-migrate.sh` step 7:
   ```
   nixos-enter --root /mnt/new --system "$TOPLEVEL" -c \
     "nix-env -p /nix/var/nix/profiles/system --set $TOPLEVEL && NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"
   ```
   Check that `/mnt/new/boot/loader/entries/` still holds `windows.conf`.
   `switch-to-configuration` manages only the NixOS entries.
10. **Unmount everything,** `cryptsetup close cryptroot`, then reboot.

## First boot

1. **The passphrase prompt.** The initrd asks for the passphrase, because no
   TPM2 slot exists yet. After the unlock, `impermanence-rollback` runs as
   usual. Its unit waits for the btrfs device, which only appears once the
   volume is open.
2. **Check:**
   - `journalctl -b -u systemd-cryptsetup@cryptroot` shows the unlock, and
     `journalctl -b -u impermanence-rollback` shows the rollback.
   - `findmnt /` shows `/dev/mapper/cryptroot[/@root]`.
   - `swapon` shows `/swap/swapfile`.
3. **Enroll the TPM2 slot** from this running system, so the binding matches
   the real boot path:
   `sudo luks-tpm2-enroll`. It runs
   `systemd-cryptenroll <device> --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7`.
4. **Enroll a recovery key:**
   `sudo systemd-cryptenroll --recovery-key /dev/disk/by-uuid/af35f49a-284f-481a-9e62-22e151185420`.
   - Write it down and store it **offline**: on paper, or in a password
     manager on another device.
   - Never put it in this repo, in `/persist`, or anywhere on this disk.
   - Test it: `sudo cryptsetup open --test-passphrase /dev/disk/by-uuid/af35f49a-…`.
5. **List the slots:** `sudo systemd-cryptenroll /dev/disk/by-uuid/af35f49a-…`
   should show password, recovery and tpm2.
   - Keep the passphrase, or drop it once the recovery key is tested
     (`--wipe-slot=password`). That is the user's call.
   - Keep at least one slot that does not depend on the TPM. The recovery key
     is that slot. systemd-cryptenroll(1) notes that enrolling a new key
     always needs an existing one to unlock.
6. **Reboot.** It should unlock with no prompt.

## Make it the committed state

One edit: add `./luks.nix` to the imports in
`hosts/galaxybook4-pro360/default.nix`. After it,
`.#nixosConfigurations.galaxybook4-pro360` must evaluate to the **same
drvPath** as `.#migration.galaxybook4-pro360-luks`. Update the README
"Optional pieces" row for luks.

## Undo

- **Before step 2.4:** nothing has changed except the shrink. To undo it:
  `btrfs filesystem resize max`.
- **During or after step 2.4, before the reboot:**
  - The data is still all there, behind the new passphrase.
  - To go back to plaintext:
    `cryptsetup reencrypt --decrypt --header /path/to/exported-header $DEV`.
    The header file must not exist yet, and must live on another disk, not on
    this filesystem (man page).
- **After the reboot:**
  - Old generations in the boot menu do **not** boot: their initrd has no
    crypttab, so it never opens the volume and waits for a btrfs device that
    never appears.
  - To go back: boot the new generation, or the USB plus `cryptsetup open`.
  - Decrypting as above is the only way back to plaintext.
- **If the data is damaged:** restore from the phase 0 backup.

## Risks, plainly

- **The shrink.** If the btrfs still uses the last 32 MiB, they are
  overwritten. Steps 2.3 and 2.5 exist for that.
- **The wrong partition.** Five of the seven partitions belong to Windows or
  Samsung recovery. Use the PARTUUID, not `nvme0n1pN`.
- **Power loss** during the rewrite: the operation records its progress in the
  LUKS2 metadata, and recovery runs on the next open (man page). Stay on AC
  with a charged battery.
- **Old plaintext.** Encrypting in place gives no guarantee that plaintext
  written before is gone from the flash: an SSD remaps blocks. The man page also
  says to treat the device as unencrypted while the operation runs. If that
  matters, the stronger route is: format a fresh LUKS2 volume (`cryptsetup
  luksFormat --uuid …`, `mkfs.btrfs -U 473402c5-…`), then restore the phase 0
  backup with `btrfs receive`. That depends entirely on the backup, and the
  received subvolumes are read-only until snapshotted writable. It is not
  scripted here.
- **TPM unlock fails** (PCR 7 changed, a firmware reset, a TPM fault): the
  boot asks for the passphrase or the recovery key, then you re-enroll.
  Losing both, along with the header backup, loses the disk.
- **Hibernation** is not set up and is a separate task (see the feature's
  header). With TPM2 and no PIN, a hibernation image is exactly as protected
  as the rest of the disk.
