# harmonia on yulee (by hand)

yulee is Ubuntu, not managed by this flake, so its binary cache is set up by
hand to match `my.binary-cache` on NixOS: harmonia-cache as a systemd unit,
`DynamicUser`, the store key handed in with `LoadCredential`, listening on
port 5000. Galaxybook lists it as `http://yulee:5000` and already trusts the
key (`yulee-1:...` in `hosts/galaxybook4-pro360/default.nix`).

Run `setup-yulee.sh` on yulee as root (`sudo bash setup-yulee.sh`). It:

1. builds harmonia from nixpkgs and pins it in a system profile,
   `/nix/var/nix/profiles/harmonia` (a GC root, so a GC on yulee keeps it);
2. writes `/etc/harmonia/config.toml` (`bind`, `priority`);
3. installs `/etc/systemd/system/harmonia.service`, signing with
   `/etc/nix/yulee-store-secret.key` (the `secret-key-files` entry of
   `/etc/nix/nix.conf`), and starts it.

Check: `curl -s http://yulee:5000/nix-cache-info` from galaxybook.

Update: rerun the script; it re-pins the profile and restarts the unit.
Remove: `systemctl disable --now harmonia && rm /etc/systemd/system/harmonia.service /nix/var/nix/profiles/harmonia*`.

Reachability: the port is not firewalled on yulee (a test instance answered
galaxybook over the tailnet, 2026-11-17). If ufw is ever enabled, allow 5000
on tailscale0 only.
