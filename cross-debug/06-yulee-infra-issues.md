# Yulee Builder Infrastructure Issues

**Not code bugs — operational issues with the remote builder.**

## SSH Pipe Breaks Under High Load

Yulee (Ryzen 9900X, remote builder via Tailscale at 100.64.0.1) drops SSH
connections during large file transfers when load avg is 20+. Build fails with
`unexpected end-of-file` on many derivations simultaneously.

Workaround: retry the rebuild. Each retry makes incremental progress as more
packages land in the local store. Also reduced builder concurrency.

## nixbld Processes Not Killed by `systemctl stop nix-daemon`

When the nix daemon is stopped via systemd, existing sandboxed build processes
(running as nixbld users) may continue. Subsequent builds inherit the high load.

Kill all nixbld workers directly:
```bash
sudo pkill -9 -u nixbld
```

## Nix Daemon Not Restarted After Killing nixbld

After `pkill -9 -u nixbld`, the nix daemon was also killed (or exited).
Rebuild then failed with:
```
error: cannot connect to socket at '/nix/var/nix/daemon-socket/socket': Connection refused
```
on every derivation.

Must restart:
```bash
sudo systemctl start nix-daemon
```

## Cache Miss Due to `wrapBintoolsWith` Overlay

The `wrapBintoolsWith` overlay in the galaxybook4-pro360 config is unconditional —
it changes every package hash, so nothing is served from cache.nixos.org. All
~5970+ packages must be built on yulee.

## Yulee Builder Settings

Initially 12 jobs caused OOM. Updated `/etc/nix/nix.conf` on yulee:
```
max-jobs = 7
cores = 6
```

## Checking Before Each Build

Before starting a rebuild, always:
```bash
ssh -i /etc/nix/remote-builder/ssh_key r0k0r@100.64.0.1 \
  'ps aux --sort=-%cpu | grep -i orca | grep -v grep | head -5; uptime'
```

Do not build if orca (Gnome accessibility process, CPU-intensive) is running on yulee.
