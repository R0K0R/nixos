{ ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  /* Old generations stay in the store until GC; frees space and pairs with boot entry limit. */
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
    persistent = true;
  };
}
