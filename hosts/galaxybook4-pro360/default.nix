{ inputs, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    # Hands the accelerometer's IIO buffer to the `input` group so the
    # vehicle-motion-cues DMS plugin can stream it without root.
    ./accelerometer.nix
    # The btrfs subvolume layout and the ephemeral root, since the live-USB
    # migration of 2026-10-24 (docs/impermanence-migration.md).
    ./impermanence.nix
  ];

  services.tailscale.enable = true;
  # Enabled here, not through my.tailscale, so the feature's state entry does not
  # apply: the node key and login, or the node re-registers after every wipe.
  my.state.system.secret.directories = [ "/var/lib/tailscale" ];
  # `tailscale up/login/set/...` as r0k0r without sudo. Tailscale has no group for
  # this: the operator is one user, stored in tailscaled's prefs, and applied by
  # the module's tailscaled-set unit on every boot.
  services.tailscale.extraSetFlags = [ "--operator=r0k0r" ];
  /*
    DNS through systemd-resolved, for tailscale's sake. Without it tailscaled ran in
    "direct" mode: it rewrote /etc/resolv.conf to 100.100.100.100 and forwarded every
    non-tailnet name to "upstream" resolvers it had captured from the network config.
    A network change (Wi-Fi roam, NetworkManager reconnect, a tunnel coming up) could
    leave that captured list empty -- then every lookup outside the tailnet got
    SERVFAIL ("dns: resolver: forward: no upstream resolvers set", journal 2026-10-08)
    until `systemctl restart tailscaled` re-captured it. With resolved, tailscale only
    registers its DNS on tailscale0 through resolved's API and NetworkManager hands the
    real upstream servers to resolved per link: nothing is captured, nothing goes stale.
    NetworkManager switches to resolved by itself when this is on.
  */
  services.resolved.enable = true;

  /*
    Two tailscale failures resolved alone does not cover (2026-10-09):

    1. Wrong clock at boot. After the battery ran flat the clock came up a month
       ahead, TLS rejected the control server's certificate ("x509: certificate has
       expired or is not yet valid"), tailscaled stayed logged out with no peers,
       and every MagicDNS name failed. Once NTP has synced, restart tailscaled if it
       is not running properly. tailscaled itself is NOT ordered after time sync:
       offline, that would stall it forever.

    2. Tailnet names not resolving with tailscale itself fine: `tailscale ip victus-15`
       answered and so did 100.100.100.100, but glibc did not -- nsncd had started
       while resolv.conf pointed at the router and kept that view. resolved removes
       that (resolv.conf stays on its stub); the watchdog below catches it, and any
       stale MagicDNS table, whatever the cause: every 2 min it resolves each online
       peer the way programs do, and restarts nscd + tailscaled on a miss, at most
       once per 10 min.
  */
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];
  systemd.services.tailscale-after-timesync = {
    description = "Restart tailscaled once the clock is synced, if it failed to log in";
    wantedBy = [ "multi-user.target" ];
    wants = [ "time-sync.target" ];
    after = [ "time-sync.target" "tailscaled.service" ];
    path = [ pkgs.tailscale pkgs.jq pkgs.systemd ];
    serviceConfig.Type = "oneshot";
    script = ''
      state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"')
      [ "$state" = Running ] || systemctl restart tailscaled
    '';
  };
  systemd.services.tailscale-dns-watchdog = {
    description = "Restart tailscaled and nscd when tailnet names stop resolving";
    path = [ pkgs.tailscale pkgs.jq pkgs.systemd pkgs.getent pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    # Checks EVERY online peer, through the system's own path (glibc via nsncd), not
    # dig at 100.100.100.100: on 2026-10-09 the resolver answered fine while glibc
    # still failed -- nsncd had started while resolv.conf pointed at the router and
    # kept using that -- and a single picked peer (another user's node) resolved
    # while victus-15 did not. Restarts nscd too, for that half.
    script = ''
      st=$(tailscale status --json 2>/dev/null) || exit 0
      [ "$(jq -r '.BackendState' <<<"$st")" = Running ] || exit 0   # the boot unit's case
      miss=""
      for peer in $(jq -r '.Peer[] | select(.Online == true) | .DNSName | rtrimstr(".")' <<<"$st"); do
        getent ahostsv4 "$peer" >/dev/null || miss="$miss $peer"
      done
      [ -n "$miss" ] || exit 0
      stamp=/run/tailscale-dns-watchdog.last
      now=$(date +%s); last=$(cat "$stamp" 2>/dev/null || echo 0)
      [ $(( now - last )) -ge 600 ] || exit 0
      echo "$now" > "$stamp"
      echo "tailnet names not resolving:$miss -- restarting nscd and tailscaled"
      systemctl restart nscd tailscaled
    '';
  };
  systemd.timers.tailscale-dns-watchdog = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "3min"; OnUnitActiveSec = "2min"; };
  };

  system.stateVersion = "26.05";

  # Kernel choice stays in the host file: it is a property of this machine's
  # hardware, not of any feature.
  boot.kernelPackages = pkgs.linuxPackages_7_2;

  my = {
    tuning = {
      # build-time accelerators for the whole tuned host set (tuning/heavy.nix).
      # Content addressing is its own feature now, my.ca-derivations below.
      heavy.enable = true;
      # The per-user half of the classifier (/var/lib/tuning-cache/<host>,
      # tuning-refresh); its one-time migration runs after this switch,
      # victus-15 first (docs/multiuser-design.md, Running the migration).
      userCache.enable = true;
      # Literal, and it must stay one: flake.nix raw-imports this file to pick
      # between the patched fork and plain upstream nixpkgs before the module
      # system exists. false here would substitute the whole package set from
      # cache.nixos.org instead of building it.
      enable = true;
      march = "meteorlake";
      intraISACross.enable = true;
      o3.enable = true;
      lto.enable = true;
      upstreamTools.enable = true;
      qtPatches.enable = true;
      refreshTool.enable = true;
    };
    # Step 1 (the daemon flag) and step 2 (the tuned host set content-
    # addressed). Set explicitly: tuning no longer implies it.
    ca-derivations.enable = true;
    # Needs ca-derivations ALREADY live on the daemon that evaluates and on
    # every builder -- forcing drvPath writes the derivation through the
    # daemon, which is what rejects it, so no client flag helps. yulee has it
    # in nix.conf; galaxybook and victus-15 need the transient drop-in in
    # features/nix/ca-derivations' header before their first switch with this on.
    # ON together: packages = "tuned" needs stripRefChecks, because a derivation
    # anywhere downstream of a CA one gets a deferred output path and any
    # reference check naming it then holds a placeholder nix rejects. 36 of
    # 919 candidates carry such a check; clearing them is the price.
    ca-derivations.packages = "tuned";
    ca-derivations.stripRefChecks = true;
    ccache.enable = true;
    # Cross-derivation reuse: patched ccache + per-package random seed. Pairs
    # with ca-derivations.packages rather than competing with it -- CA cuts off when a
    # dependency rebuilds to identical BYTES, this one when it rebuilds to
    # different bytes but identical HEADERS.
    ccache.crossDerivation.enable = true;

    # Accounts (r0k0r, primary; groups incl. dialout) come from
    # registry/hosts.nix + registry/users/ -- see lib/registry-users.nix.
    upower.enable = true;
    fonts.enable = true;
    keyd.enable = true;
    pipewire.enable = true;
    libinput.enable = true;
    swapfile.enable = true;
    discovery.enable = true;
    locale.enable = true;
    firefox.enable = true;
    fcitx.enable = true;
    openvpn = {
      enable = true;
      profileSecret = ../../age/openvpn-profile.age;
    };

    /*
      On-demand full tunnel for networks with no uplink of their own --
      `sudo globaltun up`. See globaltun-findings.md.

      yulee IS the gateway, with no jumps: it has its own uplink, so the chain
      is one hop. It used to be the jump host in front of note10, and that path
      still works, but it was three failure points for one service -- yulee,
      yulee's OpenVPN link, and a ptraced proot on the phone, whose per-syscall
      cost capped the whole tunnel near 90KB/s. Dropping the last two removes
      the slow part and the two flaky parts at once.

      The builder identity (globaltun runs as root), spelled out rather than shared,
      so the feature stays giftable. NOTE this file is a leftover: with
      remote-builder.client.sshKeySecret set, nothing installs it any more.
    */
    globaltun = {
      enable = true;
      jumps = [ ];
      remote = "r0k0r@172.30.0.215";
      sshKey = "/etc/nix/remote-builder/ssh_key";
      # One relay per client on the gateway; see the option's description for
      # the current assignment across hosts.
      remoteSocksPort = 1080;
      remotePort = 22;
      # victus-15 and yulee are both on this LAN, and they are the peers that
      # matter; without this they relayed through a DERP server in Singapore.
      # victus-15 needs no matching switch -- its keepDirect already holds the
      # LAN prefix in `main`.
      tailscaleDirect = true;

      /*
        `sudo globaltun share` hosts an AP on this machine's own card and routes
        its clients through the tunnel. The AP is a second vif on wlo1 and must
        follow its channel; share's watcher moves it along when wlo1 switches
        channel or roams.

        The passphrase lives outside the store, in a root-only file:
          printf '%s' 'the-passphrase' | sudo tee /etc/globaltun-psk
          sudo chmod 600 /etc/globaltun-psk
      */
      share = {
        enable = true;
        ssid = "gt-share";
        passwordFile = "/etc/globaltun-psk";
        stationInterface = "wlo1";
        countryCode = "KR";
      };
    };
    waydroid.enable = true;
    # KakaoTalk is the PC client under wine, a home feature -- NOT the Android
    # one under waydroid above: Kakao allows one phone plus one PC, and the
    # Android build registers as a competing primary device and evicts the
    # phone, server-side.
    session-env.enable = true;
    # benjamin's login shell (registry), as on victus-15: the vendor
    # completion paths a fish login shell wants. His fish config is his
    # home's; r0k0r's zsh config is r0k0r's home's.
    fish.systemIntegration = true;
    zsh = {
      # r0k0r's login shell is zsh (above), so the NixOS module goes on too --
      # it is what puts system packages' /share/zsh site-functions on fpath.
      # Without it completions from system packages are silently absent.
      systemIntegration = true;
      # Plugins and keybinds through programs.zsh rather than home-manager, so
      # root gets them too -- home-manager cannot reach root. home-manager's
      # own plugin switches stand down while this is on; see the option.
      systemPlugins = true;
      root = {
        enable = true;
        # One human on this machine, so `sudo -i` keeping the history of what
        # was just run is convenience with nobody to leak to. Deliberately NOT
        # the default, and deliberately naming the account rather than assuming
        # the primary one -- on a host with a second human this would put root's
        # commands in someone else's file.
        shareHistoryWith = "r0k0r";
      };
    };
    # kitty, starship, eza, the cursor theme, ssh, direnv, opencode,
    # easyeffects and the side dock are home features (~/config/home). This is
    # only the daemon side of direnv.
    direnv.enable = true;
    nix-settings.enable = true;
    # The system epoch (features/core/epoch): epoch.json in the toplevel, the
    # boot/switch history in /var/lib/nixos-epochs (persisted), every home
    # built for this host recording the epoch it was built for, hm-switch
    # (`--on victus-15 | --local | --eval-on victus-15`, epoch check advisory)
    # and hm-rollback.
    epoch.enable = true;
    # Enforcement, system-side: every greetd session goes through
    # guarded-session, so a home generation built for another epoch -- or no
    # generation at all -- gets the fallback session (cage + the system kitty
    # + a menu with Claude Code). "Hyprland (ignore epoch)" in the greeter,
    # or [s] in the fallback, starts the normal session anyway.
    fallback-session = {
      enable = true;
      guard.enable = true;
      # [s] when "Fallback" is picked from the greeter by hand.
      normalSession = "start-hyprland";
      # The home in use when this was turned on predates the epoch module;
      # true once it has been switched to a home built for this revision.
      unrecordedIsMismatch = false;
    };
    # Record each account's deployed type (/var/lib/nixos-users/<user>.type)
    # and refuse a dangerous move away from it without acceptTypeChange.
    registry.recordTypes.enable = true;
    emacs.enable = true;
    # Package sets, each owning its own list (features/<name>/packages.nix).
    base.enable = true;
    # The apps and tool sets (dev-toolchain, latex, media, astro, desktop-apps,
    # arduino, diagnostics, qt-dev, fx570ex, kakaotalk, samsung-ecosystem,
    # claude-science) are home features (~/config/home). desktop-apps' host
    # side -- themes, qt6ct, MTP, the rnote fixes -- stays here:
    desktop-apps.enable = true;
    # HWP/HWPX editor. defaultHandler is left at its default (true), so HOP
    # takes application/x-hwp from LibreOffice, which the home's desktop-apps
    # installs -- see the option's own note on why that is a separate decision.
    hop.enable = true;

    claude-code = {
      enable = true;
      # rhwp's CLI, so Claude can read HWP/HWPX documents: export-text,
      # export-markdown, export-svg, info and the rest.
      extraBinPackages = [
        (pkgs.callPackage ../../features/apps/hop/rhwp.nix { rhwpSrc = inputs.feat-hop.rhwp; })
        # Inline images in replies via kitty Unicode placeholders; see
        # ~/.claude/CLAUDE.md for how Claude is told to use it.
        (pkgs.callPackage ../../features/apps/claude-code/kitty-inline-img.nix { })
      ];
      shareWithRoot = true;
      # gemma-claude, skills, MCP servers and watermarks-remover are the
      # home's (claude-code there).
    };

    # The host side of the home's claude-desktop: Cowork's qemu and OVMF links.
    claude-desktop.enable = true;

    # Beta; `claude-science serve` then the browser. Cheap to carry: one
    # prebuilt binary and a wrapper, no Electron (see the feature's package.nix).
    # The host side of the home's claude-science: the loader, CA file and
    # /bin/bash its sandbox needs.
    claude-science.enable = true;

    # Toggle for the built-in keyboard, driven from the control centre. serio0
    # here is the i8042 KBD port; the option's description says how to confirm.
    embedded-keyboard.enable = true;
    # Cast to Miracast TVs/monitors (Wi-Fi Direct) and Chromecasts.
    wireless-display.enable = true;
    # keystone: the 3D trapezoid look of the side dock (a home feature), plus
    # scale-to-fit and the swipe -- a Hyprland patch, so the system's.
    hyprland.keystone.enable = true;
    # Galaxy Z Fold 6 as a stylus tablet (~/git_shit/foldpen): S Pen or a dummy
    # pen in, low-fps mirror out, 3-finger gestures on the phone.
    foldpen.enable = true;

    # X-Folding RGB Bluetooth keyboard: natural scroll on its trackpad without
    # inverting pinch-zoom (the firmware sends pinch as Ctrl + wheel).
    x-folding-trackpad.enable = true;

    remote-builder.client = {
      sshKeySecret = ../../age/remote-builder-ssh-key.age;
      enable = true;
      wrappers.enable = true;
      # Evaluates this system for `nixos-rebuild-victus-15`: ~19 s there vs ~39-72 s
      # here. The other peers' wrappers still evaluate on this machine.
      evalWorker = "victus-15";
      # ssh-ng, not ssh: nix queries realisations from SUBSTITUTERS to resolve a
      # content-addressed output, and ssh:// is LegacySSHStore, which has no
      # queryRealisation. It aborts with a SIGABRT stack trace rather than
      # skipping the substituter (measured 2026-09-07, nix 2.34.8).
      # nix-ssh on victus-15: its trusted builder account (my.remote-builder.server).
      # yulee is unmanaged; its own nix.conf trusts r0k0r.
      # victus-15 first: it builds and holds the worlds; yulee is shared and often loaded.
      substituters = [ "ssh-ng://nix-ssh@victus-15" "ssh-ng://r0k0r@yulee" ];
      trustedPublicKeys = [
        "yulee-1:KgdwkCN5m+hewJTk+A05PjwI3BbnZAE9NW2n634N7vM="
        "victus-15-1:W5OP8VVbu7Q7z2o5grHJ5Zp+ynm536+QVv+b8fBQJlQ="
      ];
      peers = {
        yulee = {
          # 3, matching yulee's own nix.conf. Builds dispatched over ssh-ng
          # run regardless of the remote's max-jobs, so 7 meant up to 7 builds
          # x cores=16 on a 24-thread machine that also runs simulations.
          maxJobs = 3;
          speedFactor = 10;
          # No gccarch-meteorlake -- see victus-15 below. Neither peer is an
          # Intel machine, and neither is asked to EXECUTE meteorlake code:
          # buildPlatform.canExecute hostPlatform is false here, so build-time
          # tools come from the untuned pkgsBuildBuild set. A peer only ever
          # compiles meteorlake code, which any x86_64 can do.
          #
          # When a build DOES run tuned code on a peer -- rusty-v8's mksnapshot
          # did, and SIGILLed -- that is a defect in the package's own build
          # system smuggling host flags into a build-time tool, not a missing
          # builder capability. Fix it there (qtbase's -mwaitpkg strip is the
          # precedent), rather than requiring every peer to be an Intel CPU.
          features = [ "benchmark" "big-parallel" "kvm" "nixos-test" "ca-derivations" ];
        };
        # Ryzen 5 5600H, headless. Back in the pool 2026-09-18 -- same machine,
        # not a reinstall: its ed25519 host key still matches the pin in
        # peer-victus-15.nix and the agenix recipient in secrets.nix, so no
        # re-keying was needed. Lower maxJobs/speedFactor than yulee (6 cores
        # against yulee's Zen 5) so the scheduler prefers yulee for big jobs.
        # The gccarch reasoning above applies here verbatim.
       victus-15 = {
          daemonUser = "nix-ssh";
          maxJobs = 5;
          speedFactor = 4;
          features = [ "benchmark" "big-parallel" "kvm" "nixos-test" "ca-derivations" ];
        };
      };
    };
    /*
      Goodix GXTP7936 panel. by-path, not eventN: event numbers are assigned in
      probe order and move between boots.
    */
    touch-gestures = {
      enable = true;
      device = "/dev/input/by-path/pci-0000:00:15.1-platform-i2c_designware.1-event";
    };

    /*
      One-offs that do not justify a feature. Literal list -- see
      my.packages.extra's own docs on why lookup.nix cannot read a mkIf here.
    */
    packages.extra.user = with pkgs; [
      yt-dlp
      mpv
      foliate
      localsend
      # Google Workspace CLI (googleworkspace/cli); `gws classroom` for Classroom.
      gws
    ];

    /*
      Bootstrap, done: /etc/agenix/identity.txt holds the private age key
      (root, 0600, outside the flake); its public half is in secrets.nix.
      Back that file up offline -- lose it and every age/*.age in the repo
      is permanently undecryptable, by design.

      CLI note: `agenix -d/-e` does NOT read age.identityPaths, so editing an
      existing secret needs the identity passed explicitly:
        sudo TMPDIR=/run/user/1000 agenix -e age/foo.age -i /etc/agenix/identity.txt
      (TMPDIR because agenix stages cleartext via mktemp, and /tmp here is
      btrfs-on-disk, not tmpfs. Activation itself needs none of this.)
    */
    agenix.enable = true;

    samsung-galaxybook.enable = true;

    power.enable = true;
    flatpak.enable = true;

    boot = {
      enable = true;
      extraEntries = {
        "windows.conf" = ''
          title Windows
          efi /EFI/Microsoft/Boot/bootmgfw.efi
          sort-key o_windows
        '';
        "netboot.conf" = ''
          title Netboot
          efi /EFI/netboot/netboot.xyz.efi
          sort-key o_netboot
        '';
        "asclepius.conf" = ''
          title Asclepius
          efi /EFI/Asclepius/bootx64.efi
          sort-key o_asclepius
        '';
      };
    };

    # Gnus credentials via agenix -> /run/agenix/authinfo (tmpfs, owner r0k0r).
    # features/_meta asserts my.agenix.enable alongside this.
    emacs.authinfoSecret = ../../age/authinfo.age;

    # The Doom config, its fonts and the daemon are the home's (emacs there).

    greetd.enable = true;
    qt-theming.enable = true;
    session-services.enable = true;

    desktop = {
      compositor = "hyprland";
      # 2880x1800 internal panel.
      primaryOutput = "eDP-1";
      primaryOutputScale = "1.5";
      # The vehicle-motion-cues plugin drives rotation instead of
      # iio-hyprland. Not a preference so much as arithmetic: it needs the
      # accelerometer's IIO buffer for its dots, a buffer has exactly one
      # owner, so whichever of the two starts second gets nothing. It derives
      # orientation from the gravity vector it already computes and emits the
      # same keyword batch at the same shim, so rotation behaves identically.
      autorotate = "motion-cues";
    };

    dms = {
      enable = true;
      greeter.enable = true;
    };

    # GNOME for guest and handoff (registry session = { desktop = "gnome"; },
    # pinned), and as a "GNOME" greeter entry. Scoped to its own sessions:
    # r0k0r's and benjamin's Hyprland sees none of it (the feature's header).
    gnome.enable = true;

    network = {
      enable = true;
      kdeconnect.enable = true;
    };
  };

  networking.hostName = "galaxybook4-pro360";

  # Declare the local-Qt6 build capability so packages with
  # requiredSystemFeatures = ["galaxybook-local-qt6"] can build here.
  nix.settings.system-features = [ "galaxybook-local-qt6" ];

  /*
    The buildPlatform/hostPlatform split is NOT declared here. `my.tuning.march`
    above is its single definition (tuning/nixos.nix) -- these two options used
    to be set in both places with identical values, which merged only because
    they agreed.

    Duplicating them is actively unsafe now that tuning is gated: a host-file
    definition sits OUTSIDE `mkIf my.tuning.enable`, so `enable = false` with
    `march = null` would leave a gcc.arch-carrying hostPlatform applied to plain
    upstream nixpkgs -- rebuilding the whole package set with -march while
    looking, from the host file, entirely untuned. One definition, in the module
    that owns the switch.
  */



  /*
    Host-specific overlays only. Everything generic -- the IntraISACross and
    build-load fixes, o3/LTO, upstream-tools, the i686 escape hatch -- moved to
    tuning/, behind the my.tuning.* switches above. What is left is about this
    machine's hardware and nothing else, which is why it cannot be shared.
  */
  my.tuning.extraOverlays = [
    # niri's own package set, needed wherever the niri compositor is selected.
    inputs.feat-niri.overlay

    # Meteor Lake-P integrated graphics (Intel Arc Graphics, PCI 8086:7d55)
    # is the only GPU on this laptop — no discrete AMD/NVIDIA to support.
    # Mesa's default driver lists build ~24 gallium + ~12 vulkan backends "to
    # support cross tools and emulation use cases"; trim to just what this
    # hardware needs plus a software fallback (llvmpipe/swrast — blender's own
    # test derivation uses mesa.llvmpipeHook, so keep that one rather than
    # dropping software rendering entirely).
    (final: prev: {
      mesa =
        (prev.mesa.override {
          galliumDrivers = [ "iris" "llvmpipe" ];
          vulkanDrivers = [ "intel" "swrast" ];
        }).overrideAttrs
          (old: {
            # nixpkgs' mesa flags assume the full default driver list; with the
            # trim above, three of them break or turn into dead weight (meson
            # takes the LAST occurrence of a -D flag, so appending overrides):
            mesonFlags = (old.mesonFlags or [ ]) ++ [
              # -Dauto_features=enabled force-enables the VA-API state tracker,
              # whose meson require() only accepts r600/radeonsi/nouveau/d3d12/
              # virgl -- hard configure error with iris-only. Intel VA-API is
              # provided by intel-media-driver, not mesa, so nothing is lost.
              "-Dgallium-va=disabled"
              # TFLite delegate hard-links the etnaviv/rocket/ethosu NPU
              # drivers (src/gallium/targets/teflon), all trimmed away.
              "-Dteflon=false"
              # Tools for asahi/panfrost, drivers this machine doesn't build.
              "-Dtools="
            ];
            # The spirv2dxil binary/libs only get built with the d3d12/dozen
            # drivers (trimmed away), and moveToOutput silently no-ops on
            # missing sources -- leaving the declared $spirv2dxil output
            # never created, which Nix rejects ("failed to produce output
            # path"). Same hazard for $cross_tools (pco_clc belongs to the
            # trimmed PowerVR driver). Empty outputs are valid; guarantee
            # they exist.
            postInstall = (old.postInstall or "") + ''
              mkdir -p $spirv2dxil $cross_tools
            '';
          });
    })

    /*
      Fingerprint sensor (USB 1c7a:05a1, Egis Technology "Match-On-Chip") enrolls
      and verifies successfully but forgets the print immediately: upstream
      libfprint's egismoc driver doesn't implement SDCP (Secure Device
      Communication Protocol), which these newer Egis MOC sensors require for
      the enrolled template to actually be committed to the sensor's own
      storage — enrollment silently "succeeds" without ever writing anything.
      TenSeventy7/libfprint-egismoc-sdcp implements SDCP support (device table
      confirms 0x05a1); no other patches needed (nixpkgs' libfprint has no
      patches of its own beyond build-system shebang/cross fixups, and openssl
      — the fork's one new hard dependency for SDCP's crypto handshake — is
      already a buildInput).
    */
    (final: prev: {
      libfprint = prev.libfprint.overrideAttrs (old: {
        src = prev.fetchFromGitHub {
          owner = "TenSeventy7";
          repo = "libfprint-egismoc-sdcp";
          rev = "4d128d4f6f0b46182572126e84df88a73ac27859";
          sha256 = "130b1dap0sxysg3grm5yk3fl7l072qv4vsiv9h6s69ln5gka0gwa";
        };
        # nixpkgs has since grown patches on libfprint, all of them new-hardware
        # USB product IDs (realtek-3274-9003, elan-0c58, elan-04F3-0C9C,
        # focal-077a-079a, focal-a97a) that don't apply to this fork's tree and
        # are for sensors this machine doesn't have (ours is the Egis 1c7a:05a1
        # the fork itself supports). The cross fixups live in postPatch, which
        # this override leaves intact.
        #
        # NOT `[ ]` any more: the egismoc driver aborts the whole fprintd
        # process when a task state machine is still pending at open, which on
        # this machine happened 5108 times between 2026-07-04 and 2026-09-07 --
        # every crash taking fingerprint auth down for sudo, polkit and the
        # lock screen at once. The patch turns that abort into a recoverable
        # FP_DEVICE_ERROR_BUSY. Upstream-inherited, not fork-specific: the
        # three functions involved are byte-identical in libfprint 1.94.100.
        # Tracked as TenSeventy7/libfprint-egismoc-sdcp#13, which is open with
        # no maintainer reply -- that fork's last push was 2025-07-29 and it
        # has 9 unmerged PRs, so this is not arriving from upstream.
        #
        # And the SDCP identify retry: the first verify after fprintd starts often
        # failed its SDCP MAC check (a reply to the previous daemon's request, by
        # every sign) and dropped PAM to the password although the finger matched.
        # The patch turns that into "scan again". See its header.
        patches = [
          ../../features/hardware/samsung-galaxybook/libfprint-egismoc-open-busy.patch
          ../../features/hardware/samsung-galaxybook/libfprint-egismoc-sdcp-identify-retry.patch
        ];
      });
    })
  ];
}
