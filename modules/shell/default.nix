# Shell and terminal. Each is gated by its own my.<name>.enable.
{ ... }:

{
  imports = [
    ./fastfetch
    ./fish.nix
    ./kitty.nix
  ];
}
