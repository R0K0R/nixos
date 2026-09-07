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
    direct_mode = false
    remote_storage = file:/var/cache/ccache/stage file:/var/cache/ccache/peer-victus-15|read-only=true|update-mtime=true
    CONF
    sudo chmod 664 /var/cache/ccache/l1/ccache.conf

Read per invocation; edits take effect on the next compile with no rebuild.
Drop the `peer-*` backend to go local-only; `disable = true` switches ccache
off entirely. Never set remote storage through the environment -- env is
ccache's highest-precedence source and would override this file.

## 5. Peer mount: victus-15's stage, read-only, over Tailscale

`/etc/fstab`:

    r0k0r@100.64.0.2:/var/cache/ccache/stage  /var/cache/ccache/peer-victus-15  fuse.sshfs  ro,allow_other,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,IdentityFile=/home/r0k0r/.ssh/id_ed25519,StrictHostKeyChecking=accept-new,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=20s  0 0

then `sudo systemctl daemon-reload && sudo mount /var/cache/ccache/peer-victus-15`.
A ROOT mount, not a user session mount: allow_other alone was not enough for
the daemon's stat. victus-15 authorizes `~r0k0r/.ssh/id_ed25519.pub` (added
2026-09-07). `nofail` + automount: victus being down must never block yulee.

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

## Disk

`/` on yulee is at ~96% with ~39 G free and everything above lives on it
(`/nix` is on `/`; only `/nix/store` is the 239 G device). Keep L1 at 20G and
the stage at 40G, or move `/var/cache/ccache` onto the store NVMe (btrfs
subvolume) before growing them.
