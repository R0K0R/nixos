{ pkgs, ... }:

{
  users.mutableUsers = false;

  users.users = {
    r0k0r = {
      isNormalUser = true;
      description = "Joy H.J. Lee";
      extraGroups = [ "networkmanager" "wheel" ];
      # Not tracked in git -- see secrets/ in .gitignore. Must exist at this
      # exact path on victus-15 itself; read by the activation script at
      # switch time, never embedded into the Nix store.
      hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-r0k0r";
      packages = with pkgs; [ (btop.override { cudaSupport = true; }) ];
      shell = pkgs.fish;
    };
    benjamin = {
      isNormalUser = true;
      description = "Benjamin S.H. Lee";
      extraGroups = [ "networkmanager" "wheel" ];
      hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-benjamin";
      packages = [ ];
    };
    root.hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-r0k0r";
  };

  programs.fish.enable = true;
}
