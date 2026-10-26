{ config, lib, ... }:

{
  options.my.kittyLook.enable = lib.mkEnableOption ''
    kitty in DepartureMono Nerd Font with an 8 px window margin. Layered on the kitty feature
    (features/apps/kitty), which owns programs.kitty and sets its own font and margin; these two win over it
  '';

  config = lib.mkIf config.my.kittyLook.enable {
    programs.kitty.settings = {
      # mkForce because the kitty feature defines both of these itself (another font,
      # a wider margin), and two plain definitions of one setting are an error.
      font_family = lib.mkForce "DepartureMono Nerd Font";
      # end-4 uses 21.75, which reads as a lot of dead space here -- trimmed.
      window_margin_width = lib.mkForce 8;
    };
  };
}
