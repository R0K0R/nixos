{ pkgs, ... }:

{
  services.scx = {
    enable = true;
    package = pkgs.scx.rustscheds;  # scx_bpfland is a Rust scheduler; avoids C BPF build
    scheduler = "scx_bpfland";
    extraArgs = [ "--primary-domain" "powersave" ];
  };

  powerManagement = {
    enable = true;
    cpuFreqGovernor = "powersave";  # intel_pstate active mode: acts as EPP hint
    powertop.enable = true;
  };

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="cpu", \
      RUN+="${pkgs.bash}/bin/bash -c \
        'for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; \
         do echo power > $$f; done'"
  '';
}
