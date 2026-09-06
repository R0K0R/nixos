{ config, lib, ... }:

{
  options.my.neovim.enable = lib.mkEnableOption "Neovim with the NvChad starter config, and a desktop entry that opens it in kitty";

  # Accounts this feature applies to; defaults to the primary user.
  options.my.neovim.users = import ../../lib/user-scope.nix { inherit lib config; };
}
