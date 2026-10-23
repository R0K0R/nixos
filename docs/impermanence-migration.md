# Impermanence migration — galaxybook4-pro360

The runbook for turning galaxybook4-pro360's flat btrfs into the impermanence
layout. The user does this from a live USB, together with Claude Code running
on the USB with the user's `~/.claude` copied over. **If you are that Claude:
read this whole file, then `features/core/impermanence/nixos.nix`, before
running anything.** Nothing here has been run yet: every piece was only
evaluated on 2026-10-18.

## Where things stand

- **Disk:** a btrfs on `/dev/nvme0n1p2` (UUID `473402c5-fb75-4760-afee-e10d2da78f5b`).
  It is flat: `/`, `/home` and `/nix` are ordinary folders in subvolid 5, and
  there is a 16G `/swapfile` at the top. The EFI partition is vfat, UUID `DFF1-0A5E`.
- **Design:** `~/.cache/home-classify/HANDOFF.md` §5.6 (agreed), plus the per-user
  lists in `docs/multiuser-design.md`. In short:
  - `/` is rolled back to an empty snapshot at every boot, and so is `/home`, which lives on it.
  - What survives is under `/persist`:
    - system paths: `environment.persistence`, built from the defaults and from the features' `my.state.system`;
    - per user: the user's own `my.persist` list from their home repo, merged at boot with the features' `my.state.user`.
  - **`~/Downloads` is wiped** (the user chose this).
- **Code:**
  - `features/core/impermanence`
  - `features/core/btrfs-layout`, which gains `rootSubvolume`, `persist`, `swap` and `extraMounts`
  - `lib/home-persist.nix` (the home option `my.persist`)
  - `hosts/galaxybook4-pro360/impermanence.nix` (the post-migration settings, not imported yet)
  - the flake output `migration.galaxybook4-pro360` (the host with that file and the registry changes applied)
  - `tests/impermanence-eval.sh`
- **Layout after the migration:**

| subvolume | mounted at | |
|---|---|---|
| `@root` | `/` | recreated from `@root-blank` at every boot; previous roots kept 14 days under `old-roots/` |
| `@root-blank` | | empty, read-only |
| `@nix` | `/nix` | |
| `@persist` | `/persist` | `neededForBoot` |
| `@swap` | `/swap` | swapfile at `/swap/swapfile`, made by NixOS at first boot |
| `@windows-backup` | `~/Backups/windows` | the 27G backup, kept whole (HANDOFF §5.1, which this replaces) |
| `@pre-migration` | | read-only snapshot of the old top level, **the undo** |

## Before the session (on the running laptop)

1. **Switch gb4 to the `multiuser` branch first**, the ordinary way (README:
   victus first, then gb4, home before system). The migration installs a
   system built from this branch; don't change two things at once.
2. **Review the lists:**
   - Your own: `my.persist` in `~/config/home`.
   - The features': `nix eval .#migration.galaxybook4-pro360.config.my.impermanence.userState`
     and `.config.environment.persistence`.
   - Anything not on these lists is gone after the first reboot. `imperm-diff`
     on the new system shows what a reboot would delete.
3. **Run `scripts/impermanence-prepare.sh`** from the system flake checkout.
   - It builds the post-migration system on the builders (the out-link at
     `~/impermanence-plan/system` keeps it alive through GC).
   - It writes the plan (`toplevel`, `system-dirs.txt`, `system-files.txt`,
     `user-r0k0r.json`, `user-r0k0r.persist.json`) to `~/impermanence-plan/`.
   - Rerun it after any change to the lists.
4. **Make sure anything irreplaceable is also elsewhere:**
   - KSA: `git annex sync --content` to yulee, HANDOFF §5.4.
   - The agenix identity's seed phrase (`melt`).
   - The migration only adds subvolumes and leaves the old tree in place, and
     `@pre-migration` is the undo, but a disk can still fail.
5. **Copy `~/.claude` to the USB's home**, and this repo if you want to read it there.

## On the USB

As root. The script is a dry run until `--go`, and every step can be run
again (`--step N` runs one step):

```
scripts/impermanence-migrate.sh /dev/disk/by-uuid/473402c5-fb75-4760-afee-e10d2da78f5b          # dry run
scripts/impermanence-migrate.sh /dev/disk/by-uuid/473402c5-fb75-4760-afee-e10d2da78f5b --go
```

1. Mount subvolid 5 at `/mnt/top`, then take the read-only snapshot `@pre-migration`.
2. Create `@nix` from `/nix/store` and `/nix/var` with `cp -a --reflink=always`.
   This copies metadata only and checks the copy.
3. Create `@windows-backup` from `~/windows-backup`.
4. Create `@persist`:
   - every system path in the plan;
   - for each impermanent user, every entry of `user-<name>.json` into
     `@persist/home/<name>/`, with `.persist.json` seeded from their own list.
5. Create an empty `@swap`, with `chattr +C` set.
6. Create `@root-blank` (empty, read-only), then `@root` as a snapshot of it.
7. Mount the new layout at `/mnt/new`. **Mount the EFI partition at
   `/mnt/new/boot` yourself**, then rerun step 7: it sets the system profile and installs the bootloader from inside the new root (`nixos-enter`), with the system's own Nix. Not `nixos-install`: the 26.05 ISO's Nix is older than the 2.35 store database in `@nix`.

Then reboot.

## First boot: what to check

- **The layout:** `findmnt /` shows `subvol=/@root`. `/nix`, `/persist` and
  `/swap` are mounted, and `swapon` shows `/swap/swapfile`.
- **The units:** `systemctl status impermanence-rollback` (in the journal from
  the initrd), `persist-home-r0k0r` and `hm-reactivate-r0k0r` all succeeded.
- **Login works:** the password comes from agenix, whose identity
  `/etc/agenix/identity-ed25519` is persisted by the agenix feature itself.
- **Your folders and keys are there:** `~/KSA`, `~/.ssh`, Firefox profiles, and so on.
- **What a reboot will drop:** `imperm-diff` lists it. Persist anything that
  should not be on that list, then reboot once more and check again.

## Make it the committed state

Three edits. Afterwards `.#nixosConfigurations.galaxybook4-pro360` must
evaluate to the **same drvPath** as `.#migration.galaxybook4-pro360`:

- `hosts/galaxybook4-pro360/default.nix`: `imports = [ ... ./impermanence.nix ];`
- `registry/hosts.nix`: `features.galaxybook4-pro360.impermanence = true;`
- `registry/users/r0k0r.nix`: `overrides.home = "impermanent"; acceptTypeChange = "admin->admin";`

Then `home-manager switch` in `~/config/home`, so your home writes
`.persist.json` itself from then on.

## Undo

- **Before step 7's reboot:** nothing old has changed. Boot the old system
  (it is still the default entry until step 7 installs the bootloader), or delete the new
  subvolumes.
- **After it:** every old generation still in the boot menu boots the old
  flat tree (subvolid 5). The old `/home` and `/nix` folders are untouched,
  and `@pre-migration` holds everything as it was.

## Afterwards (only once the new system has been checked)

Stage the old flat tree for deletion: the folders in subvolid 5 that are not
subvolumes, plus `/swapfile`. Like everything else, the user empties it.
`@pre-migration` can go once you are sure.
