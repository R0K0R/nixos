{ pkgs, lib, inputs, ... }:

/*
  dell-latitude -- Benjamin Lee's laptop (Comet Lake, Intel UHD).

  Ported from github:sihooleebd/nixos (his hosts/dell-latitude) onto this
  flake's conventions. What stays here is the SYSTEM: hardware, boot, the
  greeter and session enablement, services, the printer, and the remote-builder
  client. His desktop and everything under $HOME -- bonfire, flare, pyre, lyre,
  the hearth settings store, fastfetch, panelbus, neovim, the KakaoTalk Wine
  app, orbit, his Hyprland keybinds and home config, and the per-user
  application and package lists -- lives in his own home repo, a standalone
  home-manager configuration on this flake's homeLib (registry:
  homeActivation = "standalone"). The account itself is registry/users/benjamin.nix.
*/
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "dell-latitude";

  system.stateVersion = "26.05";

  # Kernel choice stays in the host file: it is a property of this machine's
  # hardware, not of any feature.
  boot.kernelPackages = pkgs.linuxPackages_7_2;

  /*
    Laptop system upgrades (plain NixOS options -- machine-appropriate, not
    feature-worthy):

      thermald  Intel's thermal daemon. Proactively manages package temp and
                throttling instead of leaving it to the kernel's reactive
                trip points.
      fwupd     Firmware/BIOS/SSD/Thunderbolt updates via LVFS; Dell has broad
                coverage. `fwupdmgr refresh && fwupdmgr update` to apply.
      zramSwap  A compressed-RAM swap device, higher priority than the
                my.swapfile file (which stays for overflow and hibernation).
                Faster than swapping to the SSD and spares it the writes.
                systemd-oomd (on by NixOS default) still guards the
                hard-pressure case.
  */
  services.thermald.enable = true;
  services.fwupd.enable = true;
  zramSwap.enable = true;

  # Portable microcode. The Latitude is Intel (its hardware-config pulls the
  # Intel blob), but this SSD also gets run on an AMD box -- the HP Victus --
  # while the Latitude is out for repair. amd-ucode rides in the initrd next to
  # intel-ucode; each CPU's early loader applies only its own, so this is free
  # on the Latitude and gives the Ryzen its microcode updates meanwhile.
  hardware.cpu.amd.updateMicrocode = true;

  # Intel VAAPI driver (iHD_drv_video.so) for hardware video de/encode on the
  # Latitude's Intel GPU (Comet Lake / UHD, Gen9.5 -> intel-media-driver).
  # Without it /run/opengl-driver/lib/dri ships only the mesa gallium drivers
  # (no Intel VAAPI), so vainfo and any h264_vaapi encode fail
  # ("va_openDriver() returns -1") -- which is what broke opendisplay-linux's
  # hardware H.264. libva on NixOS searches that dir, so dropping the driver in
  # is the whole fix; it then falls back from iHD cleanly on non-Intel hosts.
  hardware.graphics.extraPackages = [ pkgs.intel-media-driver ];

  # Wacom One Pen Display 13: the configuration GUI. There is NO Wacom Desktop
  # Center on Linux, and the KDE/GNOME Wacom panels need X11/GNOME -- so on this
  # Wayland/Hyprland session the working configurator is OpenTabletDriver. It
  # ships a config for this exact device (Wacom DTC-133 = USB 056a:03a6,
  # verified), and its GUI `otd-gui` sets active area, pressure curve, and
  # pen-button/gesture bindings. The module runs the daemon, installs udev rules,
  # and -- required for OTD to claim the tablet -- blacklists the kernel `wacom`
  # module, so the pen goes through OTD instead of libinput. The display MIRROR
  # is unaffected (that is the GPU/DRM, not the pen driver); pen->screen mapping
  # is set in OTD's output area. Needs a reboot for the blacklist to unload
  # wacom.
  hardware.opentabletdriver.enable = true;

  /*
    Steam. programs.steam (not just the package) is required on NixOS: it wraps
    Steam in its FHS environment, pulls the 32-bit graphics/runtime libraries
    (it flips hardware.graphics.enable32Bit on itself), and installs the udev
    rules for controllers. A system module a home cannot provide. Intel iGPU
    here, so expect light games only. The 32-bit set is exactly what an
    IntraISACross host refuses; this one is untuned, so it is fine.
  */
  programs.steam.enable = true;

  # Keyboard backlight auto-off: the EC turns it off after `stop_timeout` of no
  # keyboard/touchpad input (default 10s -- too eager when reading). Bump to
  # 2 min so it matches the screen's idle-dim. The dell driver encodes the value
  # as 6 bits + a unit, so "2m" (not "120s", which overflows the 6-bit field).
  # Applied on the led's `add` uevent so it survives reboots; the LED is a
  # 3-level device (off/dim/bright), this only changes WHEN it auto-offs.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="leds", KERNEL=="dell::kbd_backlight", ATTR{stop_timeout}="2m"
  '';

  # Departure Mono as the system-wide monospace, by fontconfig default rather
  # than per-app hunting: anything that asks for "monospace" gets it. The
  # nerd-fonts build, not plain departure-mono: the terminal and the bar render
  # nerd icon glyphs from their text font. JetBrains (my.fonts) stays as the
  # fallback face (fuller Unicode coverage than a pixel font), and Noto CJK
  # catches Korean. Fontconfig defaults do not reach apps that name a family
  # outright -- my.emacs.font below names it for Emacs.
  fonts.packages = [ pkgs.nerd-fonts.departure-mono ];
  fonts.fontconfig.defaultFonts.monospace = [
    "DepartureMono Nerd Font"
    "JetBrainsMono Nerd Font"
    "Noto Sans Mono CJK KR"
  ];

  # Lock screen. His home locks with hyprlock; a PAM service of its own keeps
  # it from falling back to `su`'s stack, which is slow and spawns xauth.
  security.pam.services.hyprlock = { };

  # blueman's D-Bus mechanism and polkit rules: the backend of the
  # blueman-applet in his tray, so pairing and connecting do not prompt for root
  # each time. (my.discovery enables bluez itself.)
  services.blueman.enable = true;

  # Brother DCP-T536DW (USB).
  #  - PRINT: no nixpkgs package exists for this model and it's a plain USB printer (interface
  #    07/02, NOT IPP-over-USB 07/01/04 -- so no driverless/ipp-usb), so its own colour driver is
  #    packaged from the vendor RPM (./brother-dcpt536dw.nix) and handed to CUPS. Its PPD then
  #    appears as "Brother DCP-T536DW ... for CUPS" in the printer GUI -- NixOS drivers come from
  #    the config, not the GUI's picker. CUPS + avahi themselves come from my.session-services.
  #  - SCAN: the scanner sits on a vendor-specific USB interface (class ff, not eSCL), so it needs
  #    Brother's proprietary SANE backend brscan5 (in nixpkgs). hardware.sane wires the backend +
  #    udev rules + the scanner group.
  services.printing.drivers = [ (pkgs.callPackage ./brother-dcpt536dw.nix { }) ];
  hardware.sane = {
    enable = true;
    extraBackends = [ pkgs.brscan5 ];
  };
  # Merges with the groups his registry grants give him (lib/registry.nix).
  users.users.benjamin.extraGroups = [ "scanner" "lp" ];

  my = {
    /*
      This machine builds nothing.

      `enable = false` makes flake.nix hand it plain upstream nixpkgs, so the
      entire package set substitutes from cache.nixos.org and the only things
      compiled here are the few hundred config-generated derivations every NixOS
      system produces (system-path, etc, units) -- symlink and text assembly, no
      compilers.

      Literal, and it must stay one: flake.nix raw-imports this file to choose
      the nixpkgs input BEFORE the module system exists, so mkIf/mkMerge here
      cannot be resolved. It throws rather than guessing, and an assertion in
      tuning/nixos.nix cross-checks what flake.nix read against what the module
      system evaluated.
    */
    tuning.enable = false;

    # Accounts (benjamin, primary) come from registry/hosts.nix +
    # registry/users/ -- see lib/registry-users.nix. His password is local to
    # this machine (hosts.nix localPasswords): no agenix here, so no
    # passwordSecret, and users.mutableUsers stays at its default so `passwd`
    # works.

    upower.enable = true;
    fonts.enable = true;
    keyd = {
      enable = true;
      # Caps Lock as the macOS-style language toggle: the Hangul key on a plain
      # Caps press (which the compositor config binds to the fcitx us<->hangul
      # switch), everywhere (TTY/greeter/compositor), via keyd. A plain remap,
      # not a tap-hold macro -- see features/hardware/keyd. (The "hhkb" layout
      # is the other, unrelated intent.)
      layout = "capsHangul";
      # The dorm's Topre REALFORCE 108 US had its onboard layout changed (a friend's setup), so it
      # SENDS swapped scancodes at the hardware level. DERIVED from observed behavior: with
      # `capslock=hangeul` the PHYSICAL Ctrl key produced Hangul and the PHYSICAL Caps key produced
      # Ctrl -- which means physical Ctrl emits `capslock` and physical Caps emits `leftcontrol` (and
      # physical Alt/Win are swapped too). We compensate in keyd so the physical keys do the NORMAL
      # thing on this board: physical Ctrl -> Ctrl, physical Caps -> Korean/English toggle, Alt<->Win
      # correct.
      #   - capslock    = leftcontrol : physical CTRL key (sends `capslock`)    -> Ctrl.
      #   - leftcontrol = hangeul     : physical CAPS key (sends `leftcontrol`) -> the Hangul toggle.
      #   - the alt/meta lines double-swap the firmware's Alt/Win swap back to correct.
      # keyd grabs all three Topre interfaces under the SINGLE id 0853:0147 (confirmed in
      # `journalctl -u keyd` -- NOT 001f:0b26, which is a "Generic AB13X USB Audio" device). keyd's
      # control key is `leftcontrol`, NOT `leftctrl` (the latter is silently rejected). NB this assumes
      # the CURRENT firmware swap -- if the board is ever reset to stock, delete this whole block (the
      # laptop's global capsHangul would then apply normally).
      perDevice."0853:0147" = {
        capslock = "leftcontrol"; # physical CTRL key (sends capslock) -> Ctrl
        leftcontrol = "hangeul"; # physical CAPS key (sends leftcontrol) -> Korean/English toggle
        leftalt = "leftmeta";
        leftmeta = "leftalt";
        rightalt = "rightmeta";
        rightmeta = "rightalt";
      };
    };
    pipewire.enable = true;
    libinput.enable = true;
    swapfile.enable = true;
    # Running as the primary user (benjamin). Pairings/folders are still
    # managed through the web UI (http://localhost:8384); Nix only runs the
    # daemon.
    syncthing.enable = true;
    tailscale = {
      enable = true;
      # tailscaled sometimes drops the tailnet and doesn't recover on its own; restart it when a
      # disconnect persists across two checks (`sudo systemctl restart tailscaled.service`).
      watchdog.enable = true;
    };
    discovery.enable = true;
    locale.enable = true;
    fcitx.enable = true;
    # Korean fonts + ko_KR locale + the ad blocklist for the KakaoTalk Wine app,
    # which is his home's (it is a user program).
    kakaotalk-system.enable = true;
    # iPhone/iPad as an extra display: the package, and usbmuxd for the USB
    # transport. Wi-Fi discovery is my.discovery's Avahi.
    opendisplay.enable = true;
    session-env.enable = true;
    # His login shell. systemIntegration: the NixOS module (vendor completion
    # paths, and NixOS refuses a fish login shell without programs.fish);
    # enable: the home-manager half, which his home repo receives.
    fish = {
      enable = true;
      systemIntegration = true;
    };
    kitty.enable = true;
    starship.enable = true;
    cursor-theme.enable = true;
    firefox.enable = true;
    ssh = {
      enable = true;
      # Interactive `ssh yulee`, as himself with his own key. yulee is in the
      # `injoystickly@` tailnet and this laptop is in `sihooleebd@`: a SHARED
      # node there, reachable by FQDN only (see the remote-builder peer below).
      hosts.yulee = {
        HostName = "yulee.tail2d4da1.ts.net";
        User = "benjamin";
      };
    };
    nix-settings = {
      enable = true;
      # Automatic GC is off repo-wide (fork-project artifact preservation), but
      # this host is untuned and does no fork builds -- its store just grows.
      # Weekly GC + 14-day retention (see the feature) keeps it in check.
      gc.automatic = true;
    };
    emacs = {
      enable = true;
      font = {
        family = "DepartureMono Nerd Font";
        size = 16;
      };
    };

    # Package sets the home halves of these features read from.
    base.enable = true;
    eza.enable = true;

    power = {
      enable = true;
      # Full turbo for bursts, calm fan under sustained load. Flip to
      # "performance" for max sustained clocks (louder) or "powersave" for
      # coolest/quietest. Pinned at every boot; other hosts leave PPD alone.
      profile = "performance";
    };
    flatpak.enable = true;

    boot = {
      enable = true;
      # His campfire mark over the boot scroll, until the greeter.
      plymouth.enable = true;
    };

    # The session the home needs and cannot install itself: greetd, the login
    # screen, the compositor package and its session entry, the portals and
    # services (CUPS, the Qt platform theme). His shell and panels run inside
    # that session from his home repo, which is why dms stays off.
    greetd.enable = true;
    tuigreet = {
      enable = true;
      greeting = "bonfire";
    };
    # qt-theming's home half only repairs DMS's matugen output (a user service
    # deriving a black KDE scheme from DankMatugen.colors, and qt6ct.conf edits).
    # He runs no DMS, so it applies to nobody; the system half (the QT_PLUGIN_PATH
    # entry that makes the qt6ct platform theme loadable) stays.
    qt-theming = {
      enable = true;
      users = [ ];
    };
    session-services = {
      enable = true;
      # What his desktop leans on that a bare compositor does not provide:
      # open/save dialogs through the KDE portal (Dolphin-style) with GTK apps
      # sent to the portal too, pkexec for the GUI tools that escalate through
      # it, and the broad CUPS driver set with the printer GUI (his Brother
      # model's own driver is added below).
      kdeFileChooser.enable = true;
      pkexecWrapper.enable = true;
      printing.broadDrivers.enable = true;
    };

    desktop = {
      compositor = "hyprland";
      primaryOutput = "eDP-1";
      primaryOutputScale = "0.8";
    };

    network = {
      enable = true;
      kdeconnect.enable = true;
    };

    # Hyprland: the compositor package, UWSM and the session entry stay the
    # system's; the CONFIGURATION is his own (a home module in his home repo, with
    # his keybinds and his rules), so the system's Hyprland home half applies to
    # nobody here. Left in scope it would write a second Lua config and
    # hl.config settings that merge into his.
    hyprland = {
      users = [ ];
      # His 3D dock (the "dock"-tagged windows rendered as a perspective
      # trapezoid) and his home's decoration:keystone_* options need the
      # keystone build of the compositor: the stock one rejects those keys.
      keystone.enable = true;
    };

    /*
      Offload builds to yulee and victus-15, as benjamin.

      max-jobs becomes 0 (the client sets it): this host builds NOTHING
      locally, including the doom-intermediates IFD that runs during
      evaluation. If a peer is unreachable, park it: peers.<n>.enable = false.
      That is the only lever that works; --builders cannot reach the eval step.
      See the `enable` option's description for why.

      The key is HIS OWN, hand-installed (root, 0400) at
      /etc/nix/remote-builder/ssh_key -- sshKeySecret stays null, and there is
      no agenix on this host. A different keypair from the one galaxybook
      decrypts out of age/remote-builder-ssh-key.age: two client hosts, two
      credentials, so revoking this laptop does not lock the other one out.
      The public half has to be authorised on each peer:
        yulee      unmanaged (its nix.conf is hand-administered): his account
                   there, trusted by hand, as before.
        victus-15  my.remote-builder.server.extraKeys, hosts/victus-15.

      Two tailnets: this laptop is in `sihooleebd@`; yulee and victus-15 are in
      `injoystickly@` and reach it as SHARED nodes, which get no short MagicDNS
      name -- only the FQDN resolves. `address` carries it into the peer's
      ssh_config block; /etc/nix/machines and the wrappers keep the short name.
    */
    remote-builder.client = {
      enable = true;
      wrappers.enable = true;
      flakePath = "/home/benjamin/flakes/nixos";
      # ssh-ng, as everywhere: nix queries realisations from substituters, and
      # ssh:// cannot. yulee is unmanaged, so its daemonUser is the person
      # (whose nix.conf there trusts him); victus-15 serves builds as nix-ssh.
      substituters = [ "ssh-ng://benjamin@yulee" "ssh-ng://nix-ssh@victus-15" ];
      trustedPublicKeys = [
        "yulee-1:KgdwkCN5m+hewJTk+A05PjwI3BbnZAE9NW2n634N7vM="
        "victus-15-1:W5OP8VVbu7Q7z2o5grHJ5Zp+ynm536+QVv+b8fBQJlQ="
      ];
      peers = {
        yulee = {
          maxJobs = 7;
          speedFactor = 10;
          address = "yulee.tail2d4da1.ts.net";
        };
        victus-15 = {
          daemonUser = "nix-ssh";
          maxJobs = 5;
          speedFactor = 4;
          address = "victus-15.tail2d4da1.ts.net";
        };
      };
    };
  };
}
