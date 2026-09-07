# ccache on yulee (Ubuntu 24.04, Nix 2.18.1 -- not managed by this flake)

yulee is the fastest builder and it is Ubuntu, so the NixOS half of
`features/ccache` cannot reach it. These are the manual steps that mirror it.
Everything the derivations need (`CCACHE_DIR=/var/cache/ccache/l1`, umask 002,
no remote-storage env) is baked in by `tuning/overlays/heavy.nix`; this file is
the builder half only. Steps 1-3 were done by hand on 2026-09-07.

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

## 4. ccache.conf -- the L2 lever

    sudo tee /var/cache/ccache/l1/ccache.conf <<'CONF'
    max_size = 20G
    direct_mode = false
    remote_storage = file:/var/cache/ccache/stage file:/var/cache/ccache/peer-victus-15|read-only=true|update-mtime=true
    CONF
    sudo chmod 664 /var/cache/ccache/l1/ccache.conf

Read per invocation; edits take effect on the next compile with no rebuild --
`max_size` included (it is deliberately not in the derivation env).
Drop the `peer-*` backend to go local-only; `disable = true` switches ccache
off entirely. Never set remote storage through the environment -- env is
ccache's highest-precedence source and would override this file.

## 5. Peer mount: victus-15's stage, read-only, over Tailscale

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

## 6. Trim the stage (ccache never cleans remote storage itself)

    sudo tee /etc/cron.daily/ccache-trim-stage <<'CRON'
    #!/bin/sh
    exec /nix/var/nix/profiles/default/bin/nix shell nixpkgs#ccache -c ccache --trim-dir /var/cache/ccache/stage --trim-max-size 40G --trim-method mtime
    CRON
    sudo chmod +x /etc/cron.daily/ccache-trim-stage

## 7. CA derivations (tuning/ca.nix) -- daemon-side flag

    experimental-features = nix-command flakes ca-derivations

in `/etc/nix/nix.conf`, then restart nix-daemon. The client cannot even
evaluate a CA derivation unless the DAEMON has the feature; `--extra-experimental-features`
on the command line does not help (verified).

## 8. Move /var/cache/ccache onto the store NVMe

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

    # 4. switch the store mount to the snapshot
    sudo umount /nix/store && sudo systemctl daemon-reload && sudo mount /nix/store
    findmnt -no OPTIONS /nix/store         # must contain subvol=/@store
    ls /nix/store | head -3                # store paths, no @store entry

    # 5. mount the cache subvolume, carry the dirs over, restore perms
    sudo mv /var/cache/ccache /var/cache/ccache.old
    sudo mkdir -m2775 /var/cache/ccache && sudo mount /var/cache/ccache
    sudo cp -a /var/cache/ccache.old/. /var/cache/ccache/
    sudo chown root:nixbld /var/cache/ccache /var/cache/ccache/l1 /var/cache/ccache/stage
    sudo chmod 2775        /var/cache/ccache /var/cache/ccache/l1 /var/cache/ccache/stage
    sudo btrfs property set /var/cache/ccache compression none   # entries are already compressed
    sudo rm -rf /var/cache/ccache.old

    # 6. daemon back; extra-sandbox-paths is unchanged so no nix.conf edit
    sudo systemctl start nix-daemon.socket
    nix store ping && nix build --no-link nixpkgs#hello   # smoke test

    # 7. reclaim: delete the OLD top-level copy (everything except the @-subvolumes)
    sudo mkdir -p /mnt/nixroot && sudo mount -o subvolid=5 UUID=73d5b9dd-1771-440a-91a8-068af0c2aca9 /mnt/nixroot
    ls /mnt/nixroot | grep -c '^@'         # 2
    sudo find /mnt/nixroot -mindepth 1 -maxdepth 1 ! -name '@*' -exec rm -rf {} +
    ls -A /mnt/nixroot                     # only @store @ccache
    sudo umount /mnt/nixroot && sudo rmdir /mnt/nixroot
    df -h /nix/store                       # used should be back to ~125 G

Until step 7 both copies exist and share extents, so nothing is lost by
stopping midway; to back out before step 7, restore the old fstab line and
remount. Sizes afterwards: raise `max_size` in `ccache.conf` and the cron
`--trim-max-size` freely (it is all runtime); leave the store ~40 G of
headroom. Peer mount, trim and sandbox config are unaffected.
