# Applications. Each is gated by its own my.<name>.enable, set per host in hosts/<host>.nix.
{ ... }:

{
  imports = [
    ./kakaotalk
    ./dolphin.nix
    ./packages.nix
    ./storytold.nix
    ./fractional-scale.nix
    ./firefox.nix
  ];
}
