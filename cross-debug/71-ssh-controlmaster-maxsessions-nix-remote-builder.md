# cross-debug/71: SSH ControlMaster mux fails under nix remote builder parallelism

## Problem

`nixos-rebuild switch` (delegating to yulee remote builder, max-jobs = 0) fails
mid-build with:

```
cannot build on 'ssh://r0k0r@yulee': error: 'nix-store --serve' protocol mismatch
from 'yulee', got 'started
       ControlSocket /run/nix-yulee-ssh-r0k0r@100.64.0.1:22 already exists,
       disabling multiplexing
       mux_client_request_session: session request failed: Session open refused
       by peer
```

20 builds are dispatched successfully, then the 21st fails.  Subsequent retries
fail identically.

## Root cause (three compounding issues)

### 1. Stale mux master processes

`ControlPersist yes` keeps the SSH mux master alive after each nix invocation.
When the master is killed (OOM, network drop, etc.) without removing its socket
file, the socket file remains.  The next nix connection finds the stale socket,
tries to use it, and gets `Session open refused by peer` because no process is
listening at the other end.

`rm -f /run/nix-yulee-ssh-r0k0r@100.64.0.1:22` clears the socket file, but if
the mux master *process* is still running (just the file was removed by a
previous failed attempt), the process re-owns or races for the path on next
startup.  Multiple zombie mux masters accumulate across failed rebuild attempts.

Fix: `sudo kill <pids>` for all `ssh: /run/nix-yulee-ssh-... [mux]` processes
AND `sudo rm -f /run/nix-yulee-ssh-r0k0r@100.64.0.1:22`.

### 2. Server-side MaxSessions too low

nix opens up to `maxJobs = 24` parallel build connections plus additional
substituter connections (`ssh://r0k0r@yulee` substituter), all multiplexed
through the single TCP connection the mux master holds to yulee.

yulee (Ubuntu) had `MaxSessions 20` set in a prior config layer in
`/etc/ssh/sshd_config`.  The 21st connection triggered the server-side limit.

`MaxSessions` in sshd_config uses *first-occurrence* wins semantics.  Our
appended `MaxSessions 50` was silently ignored while the earlier `MaxSessions 20`
remained active.  Confirmed with:

```bash
grep -v '^#' /etc/ssh/sshd_config | grep -i maxsessions
# MaxSessions 20   ← active (first occurrence)
# MaxSessions 50   ← ignored
```

Fix: remove all existing `MaxSessions` lines before appending the new value:

```bash
sudo sed -i '/^MaxSessions/d' /etc/ssh/sshd_config
echo 'MaxSessions 50' | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart ssh.service   # reload is not enough; restart required
```

Note: `systemctl reload` did *not* update the running limit in testing.
A full `systemctl restart` was required.

### 3. sshd_config.d include files

yulee has `Include /etc/ssh/sshd_config.d/*.conf` at the top of sshd_config.
Included files are processed *before* the main file.  Any `MaxSessions` in an
include file would take precedence over a value later in sshd_config.

Checked `50-cloud-init.conf` — contained only `PasswordAuthentication yes`,
no `MaxSessions`.  Include files are root-readable only; verify with:

```bash
sudo cat /etc/ssh/sshd_config.d/*.conf | grep -i maxsessions
```

## Sequence to recover

```bash
# 1. On the build client (galaxybook4-pro360):
sudo kill $(pgrep -f "ssh.*nix-yulee-ssh.*\[mux\]")
sudo rm -f /run/nix-yulee-ssh-r0k0r@100.64.0.1:22

# 2. On yulee (run via ssh -t yulee "sudo ..."):
sudo sed -i '/^MaxSessions/d' /etc/ssh/sshd_config
echo 'MaxSessions 50' | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart ssh.service

# 3. Re-run the rebuild (no --sudo needed for nixos-rebuild):
cd ~/flakes/nixos
nixos-rebuild switch --sudo --flake .#galaxybook4-pro360 \
  --override-input nixpkgs path:/home/r0k0r/nixpkgs-patch
```

## Files

- `modules/nixos/network/yulee.nix` — SSH client config (ControlMaster/ControlPath/ControlPersist)
- yulee `/etc/ssh/sshd_config` — runtime MaxSessions setting
