{ config, lib, ... }:

let
  cfg = config.my.boot;
in
{
  options.my.boot = {
    enable = lib.mkEnableOption "systemd-boot with a deep rollback window";

    configurationLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = ''
        Generations kept in the ESP. The ESP here is ~1GB with only ~60MB per
        generation (kernel + initrd), so there is plenty of headroom for a much
        deeper rollback window than the old 2-generation limit.
      '';
    };

    extraEntries = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = lib.literalExpression ''
        { "windows.conf" = "title Windows\nefi /EFI/Microsoft/Boot/bootmgfw.efi\n"; }
      '';
      description = ''
        Extra loader entries. An option rather than a constant because these
        name EFI binaries that exist on one particular disk -- a cloned host
        must not inherit another machine's boot menu.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.loader.systemd-boot = {
      enable = true;
      inherit (cfg) configurationLimit extraEntries;
    };

    boot.loader.efi.canTouchEfiVariables = true;
  };
}
