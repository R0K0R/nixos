{ pkgs, ... }:

{
  programs.scx = {
    enable = true;
    scheduler = "scx_bpfland";
    extraArgs = [ "--power-mode" "powersave" ];
  };

  powerManagement = {
    enable = true;
    cpuFreqGovernor = "powersave";  # intel_pstate active mode: acts as EPP hint
  };

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="cpu", \
      RUN+="${pkgs.bash}/bin/bash -c \
        'for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; \
         do echo power > $$f; done'"
  '';

  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_BAT   = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      CPU_BOOST_ON_BAT              = 0;
      CPU_SCALING_GOVERNOR_ON_AC    = "performance";
      CPU_ENERGY_PERF_POLICY_ON_AC  = "balance_performance";
      CPU_BOOST_ON_AC               = 1;
      PLATFORM_PROFILE_ON_BAT       = "low-power";
      PLATFORM_PROFILE_ON_AC        = "balanced";
    };
  };
}
