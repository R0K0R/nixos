{ ... }:

{
  boot.loader.systemd-boot = {
    enable = true;
    # ESP is ~1GB with only ~60MB/generation (kernel+initrd) — plenty of
    # headroom for a much deeper rollback window than the old 2-generation limit.
    configurationLimit = 15;
  };
  boot.loader.efi.canTouchEfiVariables = true;
}
