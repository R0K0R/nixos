{ config, lib, pkgs, ... }:

let
  cfg = config.my.desktop-apps;

  /*
    Read here rather than assembled centrally, so this feature installs its own
    packages for anyone who drops the directory into a config that has never
    heard of this repo's conventions. tuning/runtime-cache/lookup.nix reads the
    same file independently for its Tier 3 anchor set -- two consumers, one
    file, no coupling between them.
  */
  pkgSet = import ./packages.nix { inherit pkgs; };
in
{
  options.my.desktop-apps.enable = lib.mkEnableOption "GUI applications and the icon/theme packages they resolve against";

  # Accounts this feature applies to; defaults to the primary user.
  options.my.desktop-apps.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf (pkgSet ? system) { environment.systemPackages = pkgSet.system; })
    # Emitted only when non-empty, and keyed by this feature's `users`
    # scope rather than by a hardcoded account -- see lib/user-scope.nix.
    (lib.mkIf (pkgSet ? user) { my.packages.perUser = lib.genAttrs config.my.desktop-apps.users (_: pkgSet.user); })

    {
      /*
        MTP: what makes a plugged-in phone actually appear in dolphin.

        kio-extras already ships the worker (lib/qt-6/plugins/kf6/kio/mtp.so,
        linked against libmtp) and dolphin's wrapper puts kio-extras on
        QT_PLUGIN_PATH, so the SOFTWARE half has been complete all along. What
        was missing is the udev half: libmtp's 69-libmtp.rules sat unused in the
        store, so a connected phone was never tagged ID_MTP_DEVICE=1 and never
        got uaccess. The device enumerated correctly -- Samsung 04e8:6860, the
        MTP product id -- and then nothing on the host claimed it, so Solid
        never offered it and dolphin showed nothing. Diagnosed 2026-09-16.

        libmtp.out, not libmtp: the rules live in $out/lib/udev/rules.d, while
        the default output for this package is `bin`.
      */
      services.udev.packages = [ pkgs.libmtp.out ];
    }
  ]);
}
