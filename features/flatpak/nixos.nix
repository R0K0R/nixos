/*
  Flatpak, scoped to exactly one app: Sober (org.vinegarhq.Sober), a Roblox
  runtime for Linux that upstream ships only as prebuilt binaries with no
  ELF section headers -- patchelf refuses them outright ("no section
  headers, probably a statically linked self-decompressing binary"), and a
  hand-rolled buildFHSEnv sandbox gets a segfault during dynamic-linker init
  inside libloader.so, before main() even runs. Both point at deliberate
  anti-tamper hardening (Roblox's anti-cheat) that most likely checks for
  Flatpak's specific bubblewrap configuration, not just "an" FHS root.
  Tried the nix-native route first; this is the fallback, not the default.

  Everything below is infrastructure only. The app itself is a one-time
  manual step, matching how upstream expects it to be installed and keeping
  this repo from needing a Flatpak-package-management flake just for one
  proprietary, frequently-updated client:

    flatpak install flathub org.vinegarhq.Sober
*/
{ config, lib, pkgs, ... }:

{
  options.my.flatpak.enable = lib.mkEnableOption ''
    Flatpak plus the Flathub remote. Infrastructure only -- installing an app
    stays a manual `flatpak install` step
  '';

  config = lib.mkIf config.my.flatpak.enable {
  services.flatpak.enable = true;

  systemd.services.flatpak-add-flathub-repo = {
    description = "Add the Flathub Flatpak repository";
    wantedBy = [ "multi-user.target" ];
    # Was only ordered after flatpak-system-helper.service, so it ran as
    # soon as multi-user.target was reached -- frequently before
    # NetworkManager had DNS up, failing with "Could not resolve hostname".
    # network-online.target actually blocks on connectivity being ready.
    after = [ "flatpak-system-helper.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      # --if-not-exists: safe to run on every boot. Retry a few times in
      # case network-online.target fires slightly ahead of actual DNS
      # resolvability (e.g. right after a VPN/DHCP renegotiation).
      Restart = "on-failure";
      RestartSec = 5;
      StartLimitBurst = 3;
    };
    script = ''
      ${pkgs.flatpak}/bin/flatpak remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo
    '';
  };
  };
}
