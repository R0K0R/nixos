{ lib, ... }:
{
  # fastfetch with the bonfire logo (features/fastfetch/../../logo.txt). First visible piece of the
  # bonfire rebrand; see REBRAND.md.
  options.my.fastfetch.enable = lib.mkEnableOption "fastfetch system info with the bonfire logo";
}
