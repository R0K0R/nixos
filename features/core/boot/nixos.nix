{ config, lib, pkgs, ... }:

let
  cfg = config.my.boot;

  # The braille campfire mark (./logo.txt) rendered to a fire-gradient PNG,
  # wrapped in a minimal Plymouth *script* theme. It ships script.so so the
  # script module reaches the initrd too -- the NixOS plymouth module copies
  # plugins from the theme package (themesEnv), not from pkgs.plymouth.
  # ImageDir uses this store path; the module rewrites it to the initrd path
  # on its own. The art is a particular desktop's "bonfire" mark, so it is an
  # option a host asks for, not a default.
  bonfirePlymouth = pkgs.runCommand "bonfire-plymouth"
    { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pillow ])) ]; }
    ''
      d="$out/share/plymouth/themes/bonfire"
      mkdir -p "$d" "$out/lib/plymouth"
      cp ${pkgs.plymouth}/lib/plymouth/script.so "$out/lib/plymouth/"
      python3 ${./plymouth-logo.py} ${./logo.txt} "$d/logo.png"
      cp ${./bonfire.script} "$d/bonfire.script"
      substitute ${./bonfire.plymouth.in} "$d/bonfire.plymouth" --replace @themedir@ "$d"
    '';
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

    plymouth.enable = lib.mkEnableOption ''
      the "bonfire" boot splash: a braille campfire mark breathing like embers
      on a dark ground, covering the kernel/systemd/udev scroll from early boot
      until the greeter. Off by default -- the art is one person's branding,
      not something a host should inherit by enabling the boot loader
    '';

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

    /*
      Plymouth. Paired with a quiet console (kernel chatter suppressed -- see
      my.tuigreet, which sets consoleLogLevel for the same reason),
      initrd.verbose = false and quieted udev, so nothing prints over the
      splash. No "quiet" parameter: it would raise the console loglevel back to
      4, and loglevel=3 is already stricter.

      The script theme has no password dialog, so this does not fit a host with
      LUKS in the initrd; there is none on the machine that enables it.
    */
    boot.plymouth = lib.mkIf cfg.plymouth.enable {
      enable = true;
      theme = "bonfire";
      themePackages = [ bonfirePlymouth ];
    };
    boot.initrd.verbose = lib.mkIf cfg.plymouth.enable false;
    boot.kernelParams = lib.mkIf cfg.plymouth.enable [
      "splash"
      "rd.udev.log_level=3"
      "udev.log_level=3"
    ];
  };
}
