{ ... }:

{
  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.r0k0r = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ]; # Enable ‘sudo’ for the user.
  };
}
