{ pkgs, ... }:

{
  users.mutableUsers = false;

  users.users = {
    r0k0r = {
      isNormalUser = true;
      description = "Joy H.J. Lee";
      extraGroups = [ "networkmanager" "wheel" ];
      hashedPassword = "REDACTED-HASHED-PASSWORD";
      packages = with pkgs; [ (btop.override { cudaSupport = true; }) ];
      shell = pkgs.fish;
    };
    benjamin = {
      isNormalUser = true;
      description = "Benjamin S.H. Lee";
      extraGroups = [ "networkmanager" "wheel" ];
      hashedPassword = "REDACTED-HASHED-PASSWORD";
      packages = [ ];
    };
    root.hashedPassword = "REDACTED-HASHED-PASSWORD";
  };

  programs.fish.enable = true;
}
