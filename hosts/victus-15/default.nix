{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./hardware.nix
    ./fan-and-power.nix
    ./filesystems.nix
  ];

  networking.hostName = "victus-15";

  my = {
    emacs = {
      enable = true;
      # No display manager and no compositor: terminal-only build, daemon on
      # default.target, reached with `emacsclient -nw` over ssh.
      headless = true;
    };

    # Was reaching this host via modules/nixos/packages/common.nix, which
    # victus-15 imports for its "complex derivations shared across both hosts"
    # list. Now an explicit feature, so it has to be asked for.
    claude-code.enable = true;

    /*
      Same shape as galaxybook: this machine sits on the LAN side of yulee's
      OpenVPN link, so it cannot reach note10 itself and jumps through yulee.
      `sudo globaltun up` -- nothing starts on its own.

      The key is r0k0r's own ~/ssh_key, spelled absolutely because the script
      runs under sudo, where ~ is /root.
    */
    globaltun = {
      enable = true;
      jump = "r0k0r@172.30.0.215";
      remote = "root@192.168.0.100";
      sshKey = "/home/r0k0r/ssh_key";
      # Distinct from galaxybook's 1080 and yulee's 1081: one relay per client
      # on the gateway, or `up` here kills theirs.
      remoteSocksPort = 1082;
      # Headless -- keep the admin LAN off the tunnel.
      keepDirect = [ "172.20.0.0/21" ];
    };

    /*
      Both humans on this machine. Declaring an account creates it, and the
      primary is what every feature's `users` option defaults to -- so benjamin
      gets an account and a home-manager configuration, but none of the features
      scoped to the primary unless he is named explicitly.

      Password hashes come from agenix now, not from untracked files under
      /etc/nixos/secrets that had to be placed on the machine by hand and were
      invisible to the repo. passwordSecret sets hashedPasswordFile to the
      decrypted /run/agenix path, so the hash still never enters the store --
      only the ciphertext is committed.

      users.mutableUsers = false below makes a password source mandatory on
      every declared account, which features/users asserts. That also makes
      this the one migration on this host that can lock you out: prove
      decryption works BEFORE the switch that depends on it,

        sudo age -d -i /etc/ssh/ssh_host_ed25519_key age/hashed-password-r0k0r.age

      and keep the old /etc/nixos/secrets files until you have logged in on the
      new generation.

      r0k0r's file is SHARED with galaxybook -- one account, one password. If
      the two machines had drifted, this switch silently adopts galaxybook's
      hash here. benjamin exists only on this host, so his is victus-15-only.
    */
    users = {
      r0k0r = {
        primary = true;
        extraGroups = [ "networkmanager" "wheel" ];
        passwordSecret = ../../age/hashed-password-r0k0r.age;
        shell = pkgs.fish;
      };

      benjamin = {
        description = "Benjamin S.H. Lee";
        extraGroups = [ "networkmanager" "wheel" ];
        passwordSecret = ../../age/hashed-password-benjamin.age;
      };
    };

    /*
      Its own ed25519 identity, NOT a copy of galaxybook's -- see the
      ONE IDENTITY PER HOST note in secrets.nix.

      The ssh HOST key, which is agenix's documented default and exists here
      only because this host runs sshd. galaxybook has to generate a standalone
      key precisely because it does not. Nothing to create, nothing to back up:
      every secret encrypted to this key is re-derivable elsewhere (the
      password hashes also live on galaxybook, the signing key can be
      regenerated and re-trusted, the tailscale key reissued), which is the
      condition that makes a non-recoverable identity acceptable.
    */
    agenix = {
      enable = true;
      identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    };

    /*
      systemIntegration only, without my.fish.enable: r0k0r's login shell here
      is fish, so the NixOS module is wanted (vendor completion paths), but this
      host has never taken the home-manager half -- the aliases and prompt
      config -- and turning it on now would be a change of its own rather than
      part of enabling the system module. They are separate switches precisely
      so that distinction can be made.

      Replaces a bare `programs.fish.enable = true;` that used to sit further
      down this file, so the NixOS module now has one source across both hosts.
    */
    fish.systemIntegration = true;

    /*
      btop with CUDA, replacing the plain btop that features/base contributes.
      Goes through my.packages.extra rather than users.users directly: extra is
      ordered mkOrder 100, so under buildEnv's ignoreCollisions first-wins it is
      deterministically the one on PATH, and features/packages emits a warning
      naming the shadowed package instead of leaving it to module import order.
    */
    packages.extra.user = with pkgs; [ (btop.override { cudaSupport = true; }) ];

    locale = {
      enable = true;
      # Fixed installation -- no geoclue2 here and nothing to gain from
      # relocating the clock, unlike the travel laptop.
      automatic = false;
      extraLocaleSettings = {
        LC_ADDRESS = "en_US.UTF-8";
        LC_IDENTIFICATION = "en_US.UTF-8";
        LC_MEASUREMENT = "en_US.UTF-8";
        LC_MONETARY = "en_US.UTF-8";
        LC_NAME = "en_US.UTF-8";
        LC_NUMERIC = "en_US.UTF-8";
        LC_PAPER = "en_US.UTF-8";
        LC_TELEPHONE = "en_US.UTF-8";
        LC_TIME = "en_US.UTF-8";
      };
    };

    nix-settings = {
      enable = true;
      substituters = [
        "https://cache.nixos.org"
        "https://cuda-maintainers.cachix.org"
      ];
      trustedPublicKeys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
      ];
      # A host file naming its own human is fine -- that is what host files are
      # for. The invariant this refactor establishes is that FEATURES must not.
      trustedUsers = [ "r0k0r" ];
      # Was /etc/nix/signing-key.pem, untracked. Per host by definition: the
      # public half is what galaxybook lists in trusted-public-keys, so the
      # key's whole job is to say WHICH store vouched for a path.
      signingKeySecret = ../../age/nix-signing-key-victus-15.age;
    };

    network.enable = true;
    boot.enable = true;
    base.enable = true;

    /*
      One-offs that do not justify a feature. Literal list -- see
      my.packages.extra's own docs on why lookup.nix cannot read a mkIf here.
    */
    packages.extra.system = with pkgs; [
      vim
      git
      gh
      tailscale
      nbfc-linux   # fan control, driven by fan-and-power.nix
      ryzenadj     # power limits, same
    ];

    /*
      Same intra-ISA pseudo-cross arrangement as galaxybook4-pro360, only the
      arch differs. It used to be ~50 lines duplicated in this file, including
      its own copy of the i686 escape hatch guarded on "znver3" rather than
      "meteorlake" -- the same fix written twice because there was nowhere
      shared to put it.

      qtPatches stays off: pkgs-config.nix is meteorlake-specific qtbase
      patching and yulee-sandbox test exclusions, none of which applies here.
    */
    tuning = {
      # build-time accelerators for the whole tuned host set (tuning/heavy.nix) and
      # step 1 of content-addressed derivations (tuning/ca.nix). Step 2
      # (contentAddress) waits until ca-derivations is live on all three
      # machines, yulee by hand.
      heavy.enable = true;
      ca.enable = true;
      # Needs ca-derivations ALREADY live on the daemon that evaluates and on
      # every builder -- forcing drvPath writes the derivation through the
      # daemon, which is what rejects it, so no client flag helps. yulee has it
      # in nix.conf; galaxybook and victus-15 need the transient drop-in in
      # tuning/ca.nix's header before their first switch with this on.
      # OFF until yulee's Nix is newer. 2.18.1 (Ubuntu's nix-bin) cannot resolve
      # an output placeholder inside a reference specifier, so any CA package
      # whose output checks name a sibling output dies there with "illegal
      # reference specifier" -- krb5's lib output disallowing its dev output was
      # the first (2026-09-07). Not filterable at eval time: the placeholder
      # only exists after instantiation, and outputChecks itself is on nearly
      # every package. Everything else here (mold, ccache) is independent.
      ca.contentAddress = false;
      # Literal, and it must stay one -- see the note in galaxybook4-pro360.
      enable = true;
      march = "znver3";
      pseudoCross.enable = true;
      o3.enable = true;
      lto.enable = true;
      upstreamTools.enable = true;
      refreshTool.enable = true;
    };
    ccache.enable = true;
    ccache.builder = {
      enable = true;
      # yulee's write-behind stage, mounted read-only over Tailscale, so a
      # build interrupted there resumes warm here. yulee mounts ours the same
      # way by hand (features/ccache/yulee.md §5).
      peers.yulee = { host = "100.64.0.1"; };
    };
  };

  /*
    Declared accounts are the whole truth here, so every one of them needs a
    hashedPasswordFile or it becomes unloginnable at the first switch --
    features/users asserts exactly that. root is not a my.users account (it is
    not a human), so its hash is set directly.
  */
  users.mutableUsers = false;
  # Same hash as r0k0r, from the same secret -- my.users declares it, so this
  # only has to name the path it decrypts to. root is not a my.users account
  # (it is not a human), which is why it is set directly here.
  users.users.root.hashedPasswordFile = "/run/agenix/hashed-password-r0k0r";

  networking.firewall.enable = false;
  services.openssh.enable = true;

  /*
    Plain Tailscale, not features/headscale -- this talks to Tailscale's own
    coordination server. The pre-auth key was an untracked
    /var/lib/tailscale/authkey; declared here rather than behind a feature
    option because services.tailscale is configured raw here too.

    Lowest-risk of the four secrets on this host: the key is read once by
    `tailscale up` and is inert while the node stays authenticated, so a
    failure costs a re-auth rather than access.
  */
  age.secrets.tailscale-authkey.file = ../../age/tailscale-authkey-victus-15.age;

  services.tailscale = {
    enable = true;
    authKeyFile = "/run/agenix/tailscale-authkey";
  };

  # Clamshell mode -- this host runs closed-lid as a remote builder.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.stateVersion = "26.05";
}
