{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.hop;

  # Built from source against our patched rhwp fork -- see package.nix for why
  # the .deb repack could not carry the patch. Bump: the tag in flake.nix.
  hop = pkgs.callPackage ./package.nix {
    hopSrc = inputs.feat-hop.src;
    rhwpSrc = inputs.feat-hop.rhwp;
    version = inputs.feat-hop.version;
  };
in
{
  options.my.hop = {
    enable = lib.mkEnableOption ''
      HOP (Open HWP), a HWP/HWPX document editor, repackaged from upstream's .deb
    '';

    defaultHandler = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Register HOP as the default application for HWP and HWPX documents.

        Separate from `enable` because the two questions are genuinely
        independent: this config also installs LibreOffice (features/desktop-apps),
        which claims application/x-hwp through its own .desktop file and imports
        HWP with different fidelity. Installing HOP to try it is not the same
        decision as handing it every .hwp on the machine, and whichever
        association won would otherwise be decided by mimeapps list order rather
        than by anything written down.
      '';
    };
  };

  /*
    No my.internal.features entry. HOP depends on nothing else in features/ --
    it is a GTK3/WebKitGTK app that needs a graphical session and a session
    D-Bus, both of which any compositor here already provides, and neither of
    which is a feature it can assert on. That absence is what keeps the feature
    giftable: features/hop/ references one external input and no sibling.

    Worth knowing rather than asserting: Korean input into HOP arrives through
    features/fcitx, and it works via the Wayland text-input-v3 protocol that
    fcitx5's waylandFrontend speaks and GTK3's Wayland backend implements. Do
    NOT be tempted to set GTK_IM_MODULE=fcitx to "help" -- features/session-env
    documents why that variable is deliberately unset, and setting it breaks the
    native path instead of adding to it.
  */
  config = lib.mkIf cfg.enable (lib.mkMerge [
    { environment.systemPackages = [ hop ]; }

    (lib.mkIf cfg.defaultHandler {
      /*
        Both types point at HOP.desktop, the name the .deb ships (not
        hop-desktop.desktop, which is the *binary* and icon name -- they differ,
        and getting it wrong fails silently: an entry naming a nonexistent
        desktop file is skipped, leaving the association to whatever else claims
        the type).

        x-hwp is the type shared-mime-info actually defines; vnd.hancom.hwpx is
        the one package.nix adds. Listed at mkDefault so a host that wants
        LibreOffice back on top can just override it.
      */
      xdg.mime.defaultApplications = lib.mkDefault {
        "application/x-hwp" = "HOP.desktop";
        "application/vnd.haansoft-hwp" = "HOP.desktop";
        "application/vnd.hancom.hwpx" = "HOP.desktop";
      };
    })
  ]);
}
