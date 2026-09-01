{ pkgs }:

/*
  Swap the bar for the screen's orientation.

  A standalone file because BOTH halves of this feature need the same script:
  nixos.nix hands it to my.hyprland.rotationHooks (so a rotation swaps the bar),
  and home.nix runs it once from a user unit at session start (so logging in
  already rotated is not a special case). Defining it twice would be two copies
  of the transform table.

  WHY A SWAP AT ALL. Rotating takes the bar from 1920px to 1200 and DMS anchors
  its three sections independently with no width negotiation between them, so
  past a certain total they overlap. See the barConfigs comment in
  ./settings.nix for why padding cannot recover it, and why the two other
  runtime routes (widget hide, settings set barConfigs) do not work. Per-bar
  visibility does: both bars are declared and exactly one is revealed.

  Reveal-then-hide, in that order, so there is never a frame with no bar.

  Transforms 1/3/5/7 are the 90 and 270 degree rotations, flipped variants
  included; everything else is landscape.
*/
pkgs.writeShellScript "dms-bar-orientation" ''
  x="''${1:-}"
  if [ -z "$x" ]; then
    x=$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[0].transform // 0')
  fi
  case "$x" in
    1|3|5|7) want=compact; other=default ;;
    *)       want=default; other=compact ;;
  esac
  # Best-effort: DMS may not be up yet at session start, and a missing bar is
  # not worth failing a rotation over.
  dms ipc call bar reveal id "$want" >/dev/null 2>&1 || true
  dms ipc call bar hide id "$other" >/dev/null 2>&1 || true
''
