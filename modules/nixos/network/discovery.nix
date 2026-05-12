{ ... }:

{
  hardware.bluetooth.enable = true;

  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };
}
