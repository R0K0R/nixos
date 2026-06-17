{ ... }:

{
  imports = [
    ./locale/timezone.nix
    ./system/state-version.nix
    ./system/swapfile-btrfs.nix
    ./network/core.nix
    ./network/discovery.nix
    ./network/headscale-client.nix
    ./vpn/openvpn.nix
    ./desktop/niri.nix
    ./desktop/greetd.nix
    ./desktop/session-services.nix
    ./desktop/dms-greeter.nix
    ./desktop/audio-pipewire.nix
    ./desktop/libinput.nix
    ./input/keyd.nix
    ./users/r0k0r.nix
    ./fonts/default.nix
    ./nix/pkgs-config.nix
    ./nix/flake-settings.nix
    ./packages
    ./packages/session-env.nix
    ./programs/firefox.nix
    ./services/upower.nix
    ./i18n/fcitx5.nix
    ./integration/home-manager.nix

    ./virtualisation/waydroid.nix
  ];
}
