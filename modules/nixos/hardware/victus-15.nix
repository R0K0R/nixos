# HP Victus 15 (Ryzen iGPU + NVIDIA). There is no dedicated nixos-hardware profile;
# this composes commons used by similar AMD+NVIDIA Ampere laptops (e.g. HP Omen 15 Ryzen).
# Verify PRIME bus IDs after rebuild if offload misbehaves:
#   nix shell nixpkgs#pciutils -c sh -c "lspci | grep -E 'VGA|3D'"
# Format: bb:dd.f hexadecimal → PCI:<bus>:<dev>:<func> decimal (e.g. 06:00.0 → PCI:6:0:0).

{ inputs, config, lib, ... }:

{
  imports = [
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-cpu-amd-pstate
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-gpu-nvidia
    "${inputs.nixos-hardware}/common/gpu/nvidia/ampere"
    inputs.nixos-hardware.nixosModules.common-pc-laptop
    inputs.nixos-hardware.nixosModules.common-pc-ssd
  ];

  # ACPI platform profiles (same idea as HP Omen entries in nixos-hardware).
  boot = lib.mkMerge [
    (lib.mkIf (lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.1") {
      kernelModules = [ "hp-wmi" ];
    })
    {
      /* nixpkgs only adds these when services.xserver.enable is true — see
         nixos/modules/hardware/video/nvidia.nix — but greetd+Niri is Wayland-only.
         Without them, nouveau can grab the NVIDIA PCI device before the proprietary/open
         stack loads, breaking nvidia-smi and PRIME offload. */
      kernelModules = [
        "nvidia"
        "nvidia_modeset"
        "nvidia_drm"
      ];
    }
  ];

  hardware.nvidia = {
    # Enables nvidia-powerd; on many AMD+NVIDIA offload laptops it fails at start
    # (“Allocate Root client failed 0x26”) and systemd fails the whole `nixos-rebuild switch`.
    dynamicBoost.enable = lib.mkDefault false;
    prime = {
      amdgpuBusId = lib.mkDefault "PCI:6:0:0";
      nvidiaBusId = lib.mkDefault "PCI:1:0:0";
    };
  };

  services.power-profiles-daemon.enable = lib.mkDefault true;
}
