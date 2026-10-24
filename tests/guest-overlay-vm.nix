/*
  features/nix/guest-overlay, RUN: a NixOS VM test of the guest paths
  (docs/multiuser-design.md, Next 10/11). tests/guest-overlay.nix pins the
  wiring by evaluation; this boots it.

  THE HARD PART: /nix MUST BE A BTRFS SUBVOLUME. The test driver normally
  mounts the HOST's store into the VM (9p/virtiofs, plus a tmpfs overlay for
  writableStore), and useNixStoreImage gives an erofs image -- neither is a
  subvolume, so nix-guest-lower could not snapshot it. Chosen instead:

    - `rootImage` below: a btrfs filesystem image built with `mkfs.btrfs
      --rootdir`, with nix/ created as a SUBVOLUME (`--subvol nix`) holding
      the VM system's closure, and the closure's registration at
      /nix-path-registration (as make-btrfs-fs.nix does). Shrunk to fit.
    - mountHostNixStore = false, useDefaultFilesystems = false: / is that
      filesystem's top level, /nix its `nix` subvolume (my.btrfs-layout, as
      on victus-15), both from /dev/disk/by-label/guestvm.
    - The test script creates the VM's disk (machine.qcow2 in the machine's
      state directory, which the run script then uses instead of making an
      empty one) as a qcow2 overlay of the read-only image with room to grow;
      guest-vm-install.service grows the filesystem and loads the registration into
      the system's Nix database -- what a real machine's install would have.
    The kernel and initrd are still read from the host store (direct boot);
    everything after stage 1 runs from the btrfs store.

  Rejected: useNixStoreImage (erofs, read-only, not a subvolume); a disk
  image via make-disk-image (ext4 only); populating a blank disk from the
  9p host store in the initrd (slow, and needs the host store mounted).

  NOT THE REAL HOST STACK. The node imports only what the feature needs --
  features/core/_meta, features/core/btrfs-layout, features/nix/guest-overlay
  -- with my.users, my.registry.loaded and my.state stubbed to the values
  the registry would give one overlay guest (the registry wiring itself is
  tests/guest-overlay.nix's). And on PLAIN UPSTREAM nixpkgs (flake input
  nixpkgs-upstream), never the tuned set: everything substitutes from
  cache.nixos.org except the test's own small derivations.

  NOT COVERED (no network in a test VM): a substitution into the guest
  store, and a build on a builder of the guest's own. A "system switch" is
  simulated by what the activation script does: a new path in the system
  store and `systemctl restart nix-guest-lower`.

  Build (needs kvm: dispatched to a builder):
    nix build -L .#checks.x86_64-linux.guest-overlay-vm
*/
{ inputs, lib }:

let
  pkgs = inputs.nixpkgs-upstream.legacyPackages.x86_64-linux;
  label = "guestvm";

  # Stubs for the parts of the real stack the feature reads.
  stubs =
    { lib, ... }:
    {
      options.my = {
        users = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
          default = { };
        };
        registry.loaded = lib.mkOption {
          type = lib.types.raw;
          default = { };
        };
        state = lib.mkOption {
          type = lib.types.anything;
          default = { };
        };
      };
    };

  node =
    { config, pkgs, lib, ... }:
    {
      imports = [
        stubs
        ../features/core/_meta/nixos.nix
        ../features/core/btrfs-layout/nixos.nix
        ../features/nix/guest-overlay/nixos.nix
      ];

      networking.hostName = "machine";
      my.registry.loaded.hosts.features.machine = {
        "guest-overlay" = true;
        localBuilds = true;
      };
      my.users.guest.nix = "overlay";
      users.groups.guest = { };
      users.users.guest = {
        isNormalUser = true;
        uid = 1902;
        group = "guest";
        password = "guest";
      };

      my.btrfs-layout = {
        enable = true;
        device = "/dev/disk/by-label/${label}";
        nixSubvolume = "nix";
      };
      my.guest-overlay.enable = true;

      virtualisation = {
        mountHostNixStore = false;
        useNixStoreImage = false;
        writableStore = false;
        useDefaultFilesystems = false;
        memorySize = 2048;
        # mkVMOverride replaces config.fileSystems wholesale, so the
        # btrfs-layout mount is restated here from its own options.
        fileSystems = {
          "/" = {
            device = "/dev/disk/by-label/${label}";
            fsType = "btrfs";
          };
          "/nix" = {
            inherit (config.my.btrfs-layout) device;
            fsType = "btrfs";
            options = [ "subvol=${config.my.btrfs-layout.nixSubvolume}" ];
            neededForBoot = true;
          };
        };
      };

      # What an installed machine has: the store registered, the fs its size.
      # A unit, not boot.postBootCommands: the test VM boots a systemd initrd,
      # and this has to happen before nix-guest-lower snapshots the database.
      systemd.services.guest-vm-install = {
        unitConfig.DefaultDependencies = false;
        wantedBy = [ "sysinit.target" ];
        after = [ "local-fs.target" ];
        before = [
          "sysinit.target"
          "systemd-tmpfiles-setup.service"
          "nscd.service"
          "nix-daemon.socket"
          "nix-daemon.service"
          "nix-guest-lower.service"
        ];
        path = [ pkgs.util-linux pkgs.findutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${pkgs.btrfs-progs}/bin/btrfs filesystem resize max /
          if [ -f /nix-path-registration ]; then
            # mkfs.btrfs --rootdir keeps the build user's uid despite fakeroot
            # (seen: / owned by 1000). Root's, as on a real machine -- the
            # sticky merged store relies on lower objects being root's.
            # Through a second mount of the filesystem: /nix/store itself is
            # NixOS's read-only bind by now.
            top=$(mktemp -d)
            mount -t btrfs -o subvolid=5 /dev/disk/by-label/${label} "$top"
            # Only what the image brought: / itself and /nix. Activation has
            # already made /home/guest, which must stay the guest's.
            chown root:root "$top" "$top/nix-path-registration"
            find "$top/nix" -xdev \! -uid 0 -exec chown -h root:root {} +
            umount "$top" && rmdir "$top"
            ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
            rm /nix-path-registration
          fi
        '';
      };

      nix.package = pkgs.nixVersions.nix_2_35;
      nix.settings.experimental-features = [ "nix-command" ];
      environment.systemPackages = [ pkgs.bash pkgs.sqlite pkgs.btrfs-progs ];

      # The guest's test derivation: built in the guest store from a lower
      # (system) path, optionally referencing one more system path `a`.
      environment.etc."guest-test/build.nix".text = ''
        { marker, a ? null }:
        derivation {
          name = "guest-build-''${marker}";
          system = "x86_64-linux";
          # storePath: an input of the derivation, so the sandbox has it.
          builder = "''${builtins.storePath "${pkgs.bash}"}/bin/bash";
          args = [ "-c" "echo ''${marker} ''${if a == null then "" else builtins.storePath a} > $out" ];
        }
      '';
    };

in
pkgs.testers.runNixOSTest (
  { nodes, ... }:
  let
    toplevel = nodes.machine.system.build.toplevel;
    closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };
    rootImage = pkgs.runCommand "guest-overlay-vm-root.img" {
      nativeBuildInputs = [ pkgs.btrfs-progs pkgs.fakeroot pkgs.libfaketime ];
    } ''
      mkdir -p root/nix/store
      xargs -I % cp -a --reflink=auto % -t root/nix/store/ < ${closure}/store-paths
      cp ${closure}/registration root/nix-path-registration
      touch $out
      faketime -f "1970-01-01 00:00:01" fakeroot \
        mkfs.btrfs -L ${label} -r root --subvol nix --shrink $out
      btrfs check $out
    '';
  in
  {
    name = "guest-overlay";
    nodes.machine = node;

    testScript = ''
      import shlex
      import subprocess

      subprocess.run(
          ["${pkgs.qemu_test}/bin/qemu-img", "create", "-f", "qcow2",
           "-b", "${rootImage}", "-F", "raw",
           str(machine.state_dir / "machine.qcow2"), "8G"],
          check=True,
      )

      base = "/var/lib/nix-guests"
      lroot = "/nix/.guest-lower"

      def g(cmd):
          """Run cmd as the guest, in a su session (pam_namespace: their store)."""
          return machine.succeed(f"su guest -c {shlex.quote(cmd)}").strip()

      def g_fail(cmd):
          return machine.fail(f"su guest -c {shlex.quote(cmd)}")

      def current():
          return machine.succeed(f"readlink {lroot}/current").strip()

      def lower_id():
          return machine.succeed(f"cat {base}/guest/lower.id").strip()

      def new_snapshot():
          """What every activation does; returns the new snapshot's id."""
          before = current()
          machine.succeed("systemctl restart nix-guest-lower.service")
          after = current()
          assert after != before, "nix-guest-lower made no new snapshot"
          return after

      def rebased_to(snap):
          machine.wait_until_succeeds(f"test \"$(cat {base}/guest/lower.id)\" = {snap}", timeout=60)
          machine.wait_for_unit("nix-guest-overlay-guest.service")

      machine.start()
      machine.wait_for_unit("multi-user.target")

      with subtest("/nix is a btrfs subvolume with a registered store"):
          machine.succeed("findmnt -no FSTYPE /nix | grep -qx btrfs")
          machine.succeed("btrfs subvolume show /nix")
          machine.succeed("nix-store --verify-path ${toplevel}")

      with subtest("lower snapshot (nix-guest-lower)"):
          machine.succeed("test \"$(systemctl show -P Result nix-guest-lower.service)\" = success")
          snap = current()
          machine.succeed(f"btrfs subvolume show {lroot}/{snap}")
          machine.succeed(f"btrfs property get -ts {lroot}/{snap} ro | grep -qx ro=true")
          machine.succeed(f"test ! -e {lroot}/{snap}/var/nix/db/db.sqlite-wal")
          machine.succeed(
              f"test $(sqlite3 'file:{lroot}/{snap}/var/nix/db/db.sqlite?immutable=1' "
              "'select count(*) from ValidPaths') -gt 100"
          )

      with subtest("the overlay mount"):
          machine.wait_for_unit("nix-guest-overlay-guest.service")
          machine.succeed(f"findmnt -no FSTYPE {base}/.merged/guest | grep -qx overlay")
          machine.succeed(f"test \"$(stat -c '%a %U %G' {base}/.merged/guest)\" = '1775 root guest'")
          assert lower_id() == snap, f"overlay on {lower_id()}, current is {snap}"
          machine.succeed(f"btrfs subvolume show {base}/guest")

      with subtest("guest session: their store, the system's untouched"):
          # Diagnostics first (logged, never fail): what the session sees.
          machine.log(machine.execute("su guest -c 'grep -E \" /nix/store | /etc/nix | /run/wrappers \" /proc/self/mountinfo'")[1])
          machine.log(machine.execute("journalctl -b --no-pager | grep -i namespace")[1])
          # stat -f names the TOP mount; findmnt would list the system's
          # read-only bind under it too.
          fs = g("stat -f -c %T /nix/store")
          assert fs == "overlayfs", f"guest /nix/store is {fs!r}"
          g("grep -q '^store = local-overlay://' /etc/nix/nix.conf")
          g("test ! -e /run/wrappers/bin/sudo")
          info = g("nix store info 2>&1")
          machine.log(info)
          assert "local-overlay" in info, info
          # No propagation back: the system's /nix/store is still plain btrfs.
          machine.succeed("stat -f -c %T /nix/store | grep -qx btrfs")
          machine.succeed("test -e /run/wrappers/bin/sudo")

      with subtest("a build in the guest store"):
          out = g("nix-build --no-out-link /etc/guest-test/build.nix --argstr marker one")
          g(f"grep -qx one {out}")
          machine.fail(f"test -e {out}")
          machine.succeed(f"test -e {base}/guest/upper/$(basename {out})")
          kept = g("nix-build -o ~/kept /etc/guest-test/build.nix --argstr marker kept")

      with subtest("GC in the guest store"):
          g("nix-store --gc")
          g_fail(f"test -e {out}")
          g(f"test -e {kept}")
          g("test -x ${pkgs.bash}/bin/bash")
          machine.succeed(f"test -e {lroot}/{snap}/store/$(basename ${pkgs.bash})")
          machine.succeed("nix-store --verify-path ${pkgs.bash}")

      with subtest("rebase with no session: drop/copy-up after an admin GC"):
          a = machine.succeed("echo payload > /root/payload && nix-store --add /root/payload").strip()
          s1 = new_snapshot()
          rebased_to(s1)
          g(f"test -e {a}")
          r = g(f"nix-build -o ~/refs-a /etc/guest-test/build.nix --argstr marker refs --argstr a {a}")
          assert a in g(f"nix-store -q --references {r}")
          # The admin collects `a`; the next snapshot lacks it.
          machine.succeed(f"nix-store --delete {a}")
          machine.fail(f"test -e {a}")
          s2 = new_snapshot()
          rebased_to(s2)
          machine.succeed(f"test -e {base}/guest/upper/$(basename {a})")
          g(f"test -e {a}")
          g(f"nix-store --verify-path {a}")
          g(f"nix-store --verify-path {r}")

      with subtest("guest login (tty): store in the session and the user manager"):
          machine.wait_until_tty_matches("1", "login: ")
          machine.send_chars("guest\n")
          machine.wait_until_tty_matches("1", "Password: ")
          machine.send_chars("guest\n")
          machine.wait_until_tty_matches("1", "guest@machine")
          machine.wait_until_succeeds("systemctl is-active user@1902.service", timeout=60)
          machine.send_chars("stat -f -c %T /nix/store > /tmp/login-fstype\n")
          machine.wait_for_file("/tmp/login-fstype")
          assert machine.succeed("cat /tmp/login-fstype").strip() == "overlayfs"
          # The user manager (PAM service systemd-user) too.
          machine.succeed(
              "nsenter -t $(pgrep -u guest -x systemd | head -1) -m stat -f -c %T /nix/store | grep -qx overlayfs"
          )

      with subtest("a switch during the session: the session keeps its lower"):
          n = machine.succeed("echo new > /root/new && nix-store --add /root/new").strip()
          # The system builds the same derivation the guest kept: after the
          # rebase the lower has it, and the guest's upper copy must go.
          assert machine.succeed(
              "nix-build --no-out-link /etc/guest-test/build.nix --argstr marker kept"
          ).strip() == kept
          s3 = new_snapshot()
          machine.sleep(3)
          assert lower_id() == s2, f"rebased under a live session: {lower_id()}"
          machine.succeed("journalctl -u nix-guest-overlay-guest.service | grep -q 'processes alive'")
          g_fail(f"test -e {n}")
          # At most two snapshots alive: the newest and the one in use.
          machine.succeed(f"test $(find {lroot} -mindepth 1 -maxdepth 1 -type d | wc -l) -le 2")

      with subtest("logout -> rebase"):
          machine.send_chars("exit\n")
          machine.wait_until_fails("pgrep -u guest", timeout=60)
          rebased_to(s3)
          g(f"test -e {n}")
          machine.fail(f"test -e {base}/guest/upper/$(basename {kept})")
          g(f"test -e {kept}")
          g(f"nix-store --verify-path {r}")
    '';
  }
)
