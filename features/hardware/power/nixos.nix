{ config, lib, pkgs, ... }:

let
  cfg = config.my.power;
in
{
  options.my.power = {
    enable = lib.mkEnableOption "laptop power management: the sched_ext scheduler, powersave governor and EPP hint";

    scheduler = lib.mkOption {
      type = lib.types.str;
      default = "scx_bpfland";
      description = "sched_ext scheduler to run.";
    };

    schedulerArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--primary-domain" "powersave" ];
      description = "Arguments passed to the sched_ext scheduler.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.scx = {
      enable = true;
      package = pkgs.scx.rustscheds; # scx_bpfland is a Rust scheduler; avoids C BPF build
      scheduler = cfg.scheduler;
      extraArgs = cfg.schedulerArgs;
    };

    powerManagement = {
      enable = true;
      cpuFreqGovernor = "powersave"; # intel_pstate active mode: acts as EPP hint
      powertop.enable = true;
    };

    services.udev.extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="cpu", \
        RUN+="${pkgs.bash}/bin/bash -c \
          'for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; \
           do echo power > $$f; done'"
    '';
  };
}
