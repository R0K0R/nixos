{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.claude-desktop;

  # Repackaged from the .deb in Anthropic's apt repo; hash-pinned via the
  # claude-desktop-bin flake input. Bump: features/claude-desktop/update.sh.
  claude-desktop = pkgs.callPackage ./package.nix { src = inputs.claude-desktop-bin; };
in
{
  options.my.claude-desktop = {
    enable = lib.mkEnableOption "Claude Desktop (official Linux beta), repackaged from Anthropic's .deb";

    cowork = {
      enable = lib.mkEnableOption ''
        Cowork ("dispatch") microVM support: QEMU plus the OVMF firmware paths
        the app probes for.

        Opt-in, and deliberately NOT implied by `enable`. Pulling qemu into the
        closure drags in 151 otherwise-untuned packages -- its own glibc,
        systemd, gtk4 and pipewire among them -- which measured as 74% of every
        upstream-identical package in this system. That is a real cost and it
        belongs behind its own switch
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    { environment.systemPackages = [ claude-desktop ]; }

    (lib.mkIf cfg.cowork.enable {
      environment.systemPackages = [ pkgs.qemu ];

      /*
        Cowork refuses to start with "Cowork requires QEMU" even when QEMU is
        installed. The message is misleading: the gate is

          !qemuPath || !firmwarePath || !virtiofsdPath

        and all three report the same string. qemu-system-x86_64 is resolved by
        walking $PATH so it is found; virtiofsd and the guest image ship inside
        the .deb. The one that fails is firmwarePath, probed at hardcoded Debian
        absolute paths -- ["/usr/share/OVMF/OVMF_CODE_4M.fd",
        "/usr/share/OVMF/OVMF_CODE.fd"] -- and /usr/share does not exist here.

        The variables store is not probed separately; the app derives it from
        whichever CODE path matched, by literal substitution:

          e.replace("OVMF_CODE","OVMF_VARS")

        so CODE and VARS must sit beside each other under the same name stem, and
        must be a matched pair (pflash sizes have to agree) -- hence both links
        into the same OVMF build rather than two independently-resolved paths.

        Symlinking rather than patching app.asar: blacken.py can only do
        same-length byte replacements, and a /nix/store path is far longer than
        the Debian one. This also survives Claude Desktop updates.
      */
      systemd.tmpfiles.rules = [
        "d /usr/share/OVMF 0755 root root -"
        "L+ /usr/share/OVMF/OVMF_CODE.fd - - - - ${pkgs.OVMF.firmware}"
        "L+ /usr/share/OVMF/OVMF_VARS.fd - - - - ${pkgs.OVMF.variables}"
      ];
    })
  ]);
}
