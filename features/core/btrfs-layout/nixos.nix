/*
  /nix as its own btrfs subvolume.

  What needs it: guest-overlay snapshots /nix (store AND database, one atomic
  point in time) as the frozen lower layer of every guest's overlay store,
  and `btrfs subvolume snapshot` takes a subvolume, not a directory.

  victus-15 already has it (subvolume "nix", id 257, made when the machine
  was set up); this feature just declares that mount. galaxybook4-pro360 has
  / = the top-level subvolume with /nix a plain directory, so turning it on
  there needs the one-time migration below FIRST -- the mount would point at
  a subvolume that does not exist, and the boot would drop to the emergency
  shell.

  Migration (offline: from a live USB, or at least with nix-daemon stopped and
  nothing running from the store but the shell doing it). Not scripted on
  purpose -- it is run once per machine, by a person watching it:

    mount -o subvolid=5 /dev/disk/by-uuid/<root> /mnt
    btrfs subvolume create /mnt/@nix
    cp -a --reflink=always /mnt/nix/. /mnt/@nix/     # metadata only, no data copy
    mv /mnt/nix /mnt/nix.old && mkdir /mnt/nix       # keep the old tree until it boots
    # enable my.btrfs-layout in the host file and make that generation the
    # boot default (nixos-enter --root /mnt, then switch-to-configuration
    # boot), reboot, check that `findmnt /nix` shows subvol=/@nix, then:
    rm -rf /mnt/nix.old                              # a plain directory, not a subvolume

  Only the declaration lives here: device, subvolume name, mount options.
*/
{ config, lib, ... }:

let
  cfg = config.my.btrfs-layout;
in
{
  options.my.btrfs-layout = {
    enable = lib.mkEnableOption ''
      /nix mounted from its own btrfs subvolume (`nixSubvolume` on `device`).
      Needs the one-time migration in features/core/btrfs-layout/nixos.nix
      done first'';

    device = lib.mkOption {
      type = lib.types.str;
      default = config.fileSystems."/".device or "";
      defaultText = lib.literalExpression ''config.fileSystems."/".device'';
      description = "The btrfs filesystem holding the subvolume (by default the one / is on).";
    };

    nixSubvolume = lib.mkOption {
      type = lib.types.str;
      default = "@nix";
      description = "Subvolume mounted at /nix, relative to the top-level subvolume.";
    };

    extraOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "compress=zstd" ];
      description = "Mount options after subvol=. (NixOS already mounts /nix in the initrd.)";
    };

    /*
      THE REST OF THE LAYOUT, each part off unless set: what an ephemeral root
      (features/core/impermanence) needs around it. victus-15 uses only the
      /nix part above. The galaxybook layout planned for impermanence
      (~/.cache/home-classify/HANDOFF.md §5.6; docs/impermanence-migration.md):

        @root        /             rolled back to @root-blank at every boot
        @root-blank                the empty snapshot @root is reset to
        @nix         /nix
        @persist     /persist      what survives (system and per-user)
        @swap        /swap         the swapfile (nodatacow, never snapshotted)
        @windows-backup  <home>/Backups/windows   (extraMounts)
    */
    rootSubvolume = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "@root";
      description = "Subvolume mounted at / (null: / stays as hardware-configuration.nix says).";
    };

    persist = {
      enable = lib.mkEnableOption "the @persist subvolume, mounted in the initrd (impermanence's persistRoot)";
      subvolume = lib.mkOption {
        type = lib.types.str;
        default = "@persist";
        description = "Subvolume holding everything that survives an ephemeral root.";
      };
      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/persist";
        description = "Where it is mounted.";
      };
    };

    swap = {
      enable = lib.mkEnableOption "the @swap subvolume at /swap, home of the swapfile (my.swapfile.path)";
      subvolume = lib.mkOption {
        type = lib.types.str;
        default = "@swap";
        description = "Subvolume for the swapfile: its own, so no root snapshot or rollback ever holds it.";
      };
    };

    extraMounts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.subvolume = lib.mkOption {
            type = lib.types.str;
            description = "Subvolume mounted here.";
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        { "''${config.users.users.<primary>.home}/Backups/windows".subvolume = "@windows-backup"; }
      '';
      description = "Further subvolumes, by mount point -- data kept whole and outside every snapshot.";
    };
  };

  config = lib.mkMerge [
    { my.internal.features.btrfs-layout.enabledBy = cfg.enable; }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = (config.fileSystems."/".fsType or "") == "btrfs" && cfg.device != "";
          message = "my.btrfs-layout: / must be btrfs (and my.btrfs-layout.device set) -- the subvolume lives on the same filesystem.";
        }
      ];
      fileSystems =
        {
          "/nix" = {
            inherit (cfg) device;
            fsType = "btrfs";
            options = [ "subvol=${cfg.nixSubvolume}" ] ++ cfg.extraOptions;
          };
        }
        // lib.optionalAttrs (cfg.rootSubvolume != null) {
          "/".options = [ "subvol=${cfg.rootSubvolume}" ] ++ cfg.extraOptions;
        }
        // lib.optionalAttrs cfg.persist.enable {
          ${cfg.persist.mountPoint} = {
            inherit (cfg) device;
            fsType = "btrfs";
            options = [ "subvol=${cfg.persist.subvolume}" ] ++ cfg.extraOptions;
            # Bind mounts from it are set up before stage 2 (impermanence).
            neededForBoot = true;
          };
        }
        // lib.optionalAttrs cfg.swap.enable {
          "/swap" = {
            inherit (cfg) device;
            fsType = "btrfs";
            # No compression on the swap subvolume: btrfs refuses swapfiles on
            # compressed or CoW extents (mkswapfile sets nodatacow itself).
            options = [ "subvol=${cfg.swap.subvolume}" "noatime" ];
          };
        }
        // lib.mapAttrs (_: m: {
          inherit (cfg) device;
          fsType = "btrfs";
          options = [ "subvol=${m.subvolume}" ] ++ cfg.extraOptions;
        }) cfg.extraMounts;
    })
  ];
}
