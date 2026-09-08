# ccache on yulee (Ubuntu 24.04, Nix 2.18.1 -- not managed by this flake)

yulee is the fastest builder and it is Ubuntu, so the NixOS half of
`features/ccache` cannot reach it. These are the manual steps that mirror it.
Everything the derivations need (`CCACHE_DIR=/var/cache/ccache/l1`, umask 002,
no remote-storage env) is baked in by `tuning/overlays/heavy.nix`; this file is
the builder half only. All steps were done by hand on 2026-09-07; kept as the
record of yulee's state and for rebuilding it.

## 1. Directories (done)

    sudo mkdir -p -m2775 /var/cache/ccache /var/cache/ccache/l1 /var/cache/ccache/stage
    sudo chown root:nixbld /var/cache/ccache /var/cache/ccache/l1 /var/cache/ccache/stage
    sudo mkdir -p -m0755 /var/cache/ccache/peer-victus-15

Group-writable for the ten `nixbld` users, world-readable so `ccache -s` and
trimming work from outside the group. Do NOT use 0770/umask 007: stats become
unreadable and look like an empty cache.

## 2. Sandbox (done) -- PARENT ONLY

`/etc/nix/nix.conf`:

    sandbox = true
    extra-sandbox-paths = /var/cache/ccache

then `sudo systemctl restart nix-daemon`. Do not list the peer mountpoint
itself: the daemon stats every listed path at sandbox setup and a FUSE
mountpoint fails that stat with "Permission denied" (root can read it fine;
measured). With the parent listed, the bind is recursive and the submount
rides along.

## 3. FUSE (done)

    echo user_allow_other | sudo tee -a /etc/fuse.conf

## 4. ccache.conf -- the L2 lever (done)

    sudo tee /var/cache/ccache/l1/ccache.conf <<'CONF'
    max_size = 20G
    direct_mode = false
    remote_storage = file:/var/cache/ccache/stage file:/var/cache/ccache/peer-victus-15|read-only=true|update-mtime=true
    CONF
    sudo chmod 664 /var/cache/ccache/l1/ccache.conf

Read per invocation; edits take effect on the next compile with no rebuild --
`max_size` included (it is deliberately not in the derivation env).

MUST BE A REAL FILE, never a symlink into the store. A build sandbox's
/nix/store contains only that derivation's own inputs, so a store symlink
dangles inside the sandbox and ccache silently falls back to its defaults:
direct_mode on, no remote storage, 5 GiB cache -- while `ccache --show-config`
from a login shell still reports the intended values. That is exactly how
victus-15 ran unnoticed (its NixOS module used a tmpfiles `L+`), and it is why
the module now uses `C+`.

`max_size` is easy to omit and expensive to omit: without it ccache uses its
5 GiB default, and on a full-world rebuild the cache thrashes, evicting entries
as fast as it writes them. Measured on yulee: 5.0/5.0 GiB at 99.86%, 13.9% hit
rate.
Drop the `peer-*` backend to go local-only; `disable = true` switches ccache
off entirely. Never set remote storage through the environment -- env is
ccache's highest-precedence source and would override this file.

## 5. Peer mount: victus-15's stage, read-only, over Tailscale (done)

`/etc/fstab`:

    r0k0r@100.64.0.2:/var/cache/ccache/stage  /var/cache/ccache/peer-victus-15  fuse.sshfs  ro,allow_other,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,IdentityFile=/home/r0k0r/.ssh/id_ed25519,StrictHostKeyChecking=accept-new,_netdev,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=20s  0 0

then `sudo systemctl daemon-reload && sudo mount /var/cache/ccache/peer-victus-15`.
No `nofail`: util-linux 2.39 passes it through to `mount.fuse3`, which
rejects it (`fuse: unknown option(s): -o nofail`); it is redundant anyway,
the automount never blocks boot and `mount-timeout` bounds the wait.
A ROOT mount, not a user session mount: allow_other alone was not enough for
the daemon's stat. victus-15 authorizes `~r0k0r/.ssh/id_ed25519.pub` (added
2026-09-07). Automount: victus being down must never block yulee.

Sanity: `tailscale ping 100.64.0.2` must say `via <ip>:41641` (direct), not
`via DERP` -- a relay multiplies every per-op cost.

## 6. Trim the stage (done; ccache never cleans remote storage itself)

    sudo tee /etc/cron.daily/ccache-trim-stage <<'CRON'
    #!/bin/sh
    exec /nix/var/nix/profiles/default/bin/nix shell nixpkgs#ccache -c ccache --trim-dir /var/cache/ccache/stage --trim-max-size 40G --trim-method mtime
    CRON
    sudo chmod +x /etc/cron.daily/ccache-trim-stage

## 7. CA derivations (tuning/ca.nix) -- daemon-side flag (done)

    experimental-features = nix-command flakes ca-derivations

in `/etc/nix/nix.conf`, then restart nix-daemon. The client cannot even
evaluate a CA derivation unless the DAEMON has the feature; `--extra-experimental-features`
on the command line does not help (verified).

## 8. Move /var/cache/ccache onto the store NVMe (done)

`/` (ext4, 937 G) is at 96% with ~40 G free, so L1 20 G + stage 40 G do not
fit there. The 239 G btrfs on `nvme2n1` has ~105 G free, BUT it is mounted
with its TOP LEVEL as `/nix/store` (`subvol=/`). A subvolume created there
would show up as `/nix/store/<name>`, and Nix's GC deletes store entries it
cannot parse as store paths -- it would wipe the cache. So the disk is first
restructured into `@store` + `@ccache`. The snapshot is instant (CoW); the
only slow part is deleting the old top-level copy afterwards (minutes).

Preconditions: no builds running, nothing else using `/nix/store`.

    # 1. stop the daemon; nix binaries live in the store, so use only Ubuntu tools below
    sudo systemctl stop nix-daemon.socket nix-daemon.service
    sudo fuser -vm /nix/store            # must print nothing

    # 2. snapshot the top level into a subvolume, create the cache subvolume
    sudo btrfs subvolume snapshot /nix/store /nix/store/@store
    sudo btrfs subvolume create   /nix/store/@ccache
    sudo btrfs subvolume list /nix/store  # expect: @store, @ccache

    # 3. fstab: the store line gets subvol=@store; the cache gets its own line
    #    (keep it ABOVE the peer-victus-15 line; systemd orders nested mounts anyway)
    sudo sed -i 's#^UUID=73d5b9dd-1771-440a-91a8-068af0c2aca9 /nix/store btrfs compress=zstd 0 2#UUID=73d5b9dd-1771-440a-91a8-068af0c2aca9 /nix/store        btrfs subvol=@store,compress=zstd,noatime 0 2\nUUID=73d5b9dd-1771-440a-91a8-068af0c2aca9 /var/cache/ccache btrfs subvol=@ccache,noatime 0 2#' /etc/fstab
    grep -n 73d5b9dd /etc/fstab            # two lines

    # 4. switch the store mount to the snapshot. `umount /nix/store` says
    #    "target is busy" (every running Nix-built process, the login shell
    #    included, has binaries mapped from it) and `mount` refuses to stack
    #    the same device on the same mountpoint -- so mount elsewhere and
    #    bind it over. The old top-level mount stays underneath until the
    #    next reboot, when fstab mounts @store directly.
    sudo mkdir -p /mnt/newstore
    sudo mount -o subvol=@store,compress=zstd,noatime UUID=73d5b9dd-1771-440a-91a8-068af0c2aca9 /mnt/newstore
    sudo mount --bind /mnt/newstore /nix/store
    sudo umount -l /mnt/newstore && sudo rmdir /mnt/newstore
    findmnt -no SOURCE,FSROOT /nix/store   # /dev/nvme2n1  /@store
    ls -A /nix/store | grep -c '^@'        # 0

    # 5. mount the cache subvolume, carry the dirs over, restore perms
    #    (stop the peer automount first: an autofs mountpoint inside blocks the mv)
    sudo systemctl stop 'var-cache-ccache-peer\x2dvictus\x2d15.automount'
    sudo mv /var/cache/ccache /var/cache/ccache.old
    sudo mkdir -m2775 /var/cache/ccache && sudo mount /var/cache/ccache
    sudo cp -a /var/cache/ccache.old/. /var/cache/ccache/
    sudo chown root:nixbld /var/cache/ccache /var/cache/ccache/l1 /var/cache/ccache/stage
    sudo chmod 2775        /var/cache/ccache /var/cache/ccache/l1 /var/cache/ccache/stage
    sudo btrfs property set /var/cache/ccache compression none   # entries are already compressed
    sudo rm -rf /var/cache/ccache.old

    # 6. daemon back; extra-sandbox-paths is unchanged so no nix.conf edit
    sudo systemctl start nix-daemon.socket 'var-cache-ccache-peer\x2dvictus\x2d15.automount'
    nix store ping && nix build --no-link nixpkgs#hello   # smoke test

    # 7. reclaim: delete the OLD top-level copy (everything except the @-subvolumes)
    sudo mkdir -p /mnt/nixroot && sudo mount -o subvolid=5 UUID=73d5b9dd-1771-440a-91a8-068af0c2aca9 /mnt/nixroot
    ls /mnt/nixroot | grep -c '^@'         # 2
    sudo find /mnt/nixroot -mindepth 1 -maxdepth 1 ! -name '@*' -exec rm -rf {} +
    ls -A /mnt/nixroot                     # only @store @ccache
    sudo umount /mnt/nixroot && sudo rmdir /mnt/nixroot
    df -h /nix/store                       # unchanged (~126 G): the copies shared every extent

The deletion in step 7 takes a while (millions of unlinks, the .links
hard-link farm included); it is not hung. Until step 7 both copies exist and share extents, so nothing is lost by
stopping midway; to back out before step 7, restore the old fstab line and
remount. Sizes afterwards: raise `max_size` in `ccache.conf` and the cron
`--trim-max-size` freely (it is all runtime); leave the store ~40 G of
headroom. Peer mount, trim and sandbox config are unaffected.

## 9. Nix version -- required for content-addressed derivations

Ubuntu ships `nix-bin` 2.18.1 and has nothing newer (`apt-cache policy nix-bin`
lists it as both Installed and Candidate), so `apt upgrade` cannot help. That
version cannot resolve an output placeholder inside a reference specifier, so
any CA package whose output checks name a sibling output fails here with

    derivation contains an illegal reference specifier '/1lba4bnb...'

krb5's `lib` output disallowing its own `dev` output was the first to hit it
(2026-09-07). Every BUILDER needs the newer Nix, not just the evaluator.
nixpkgs offers 2.34.8, matching victus-15.

    # 1. upstream Nix into the SYSTEM profile, built by the current one
    sudo -i nix --extra-experimental-features 'nix-command flakes' \
      profile install --profile /nix/var/nix/profiles/default nixpkgs#nix

    # 2. make it win on PATH. THIS is the one that matters: an ssh-ng remote
    #    build spawns `nix-daemon --stdio` from the SSH session's PATH, not
    #    from the systemd unit, and that PATH has /usr/local/bin ahead of
    #    /usr/bin (checked) while ~/.local/bin is earlier still.
    for b in /nix/var/nix/profiles/default/bin/nix*; do
      sudo ln -sf "$b" "/usr/local/bin/$(basename "$b")"
    done

    # 3. the local daemon too -- Ubuntu's unit runs /usr/bin/nix-daemon
    sudo systemctl edit nix-daemon    # add:
    #   [Service]
    #   ExecStart=
    #   ExecStart=/nix/var/nix/profiles/default/bin/nix-daemon --daemon
    sudo systemctl daemon-reload && sudo systemctl restart nix-daemon

    # 4. stop apt putting 2.18 back under a migrated store
    sudo apt-mark hold nix-bin nix-setup-systemd

    # 5. verify from GALAXYBOOK, which is what remote builds actually use
    ssh yulee 'nix --version; command -v nix'

ONE WAY. A newer Nix migrates the store's SQLite schema on first use and 2.18
will not read it afterwards, which is why step 4 is not optional.
