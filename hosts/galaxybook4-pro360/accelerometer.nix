/*
  Accelerometer access for features/dms/plugins/vehicle-motion-cues.

  Host-scoped: accel_3d is this machine's HID sensor hub, and the measurements
  below were taken on it.

  WHY A UDEV RULE IS UNAVOIDABLE. The plugin needs a continuous stream of
  acceleration, and the unprivileged interface cannot give one. Polling
  the per-device in_accel_{x,y,z}_raw files under /sys/bus/iio/devices returns
  a single frozen
  cached report from the HID sensor hub however fast you read it -- measured on
  this machine, as root, while it was being deliberately tilted:

      sysfs polling   393 polls, 1 fresh in 12.0s ->  0.1 Hz  (axis spread 0,0,0)
      IIO buffer     1186 records in 12.0s        -> 98.8 Hz

  Those files only go live if reads are spaced a second or more apart, which
  caps the honest rate near 1 Hz. The trigger buffer streams properly and also
  accepted a sampling-frequency bump from 10 Hz to 100 Hz, but its sysfs knobs
  and the /dev chardev are root-only by default. This rule hands them to a
  group; nothing runs as root at runtime.

  CONSEQUENCE FOR AUTOROTATION. Only one process can hold an IIO buffer, so
  the plugin and iio-sensor-proxy cannot both have the accelerometer. That is
  why the plugin also serves orientation (see plugins.nix) and why
  iio-hyprland is not started alongside it.
*/
{ pkgs, ... }:

let
  # The login user is already in `input`, the conventional group for sensor
  # devices.
  group = "input";

  # udev's RUN+= gets a minimal environment and needs absolute paths, so the
  # work is a script in the store rather than an inline one-liner. GROUP=/MODE=
  # only cover the device NODE, so the sysfs attributes used to arm the buffer
  # are handed over explicitly here. buffer/ and buffer0/ are both attempted
  # because which one the kernel exposes is version-dependent.
  openBuffer = pkgs.writeShellScript "iio-accel-open-buffer" ''
    dev="/sys$1"
    for d in "$dev/buffer" "$dev/buffer0" "$dev/scan_elements"; do
      [ -d "$d" ] || continue
      ${pkgs.coreutils}/bin/chgrp -R ${group} "$d" || true
      ${pkgs.coreutils}/bin/chmod -R g+w "$d" || true
    done
    f="$dev/in_accel_sampling_frequency"
    if [ -e "$f" ]; then
      ${pkgs.coreutils}/bin/chgrp ${group} "$f" || true
      ${pkgs.coreutils}/bin/chmod g+w "$f" || true
    fi
  '';
in
{
  services.udev.extraRules = ''
    SUBSYSTEM=="iio", KERNEL=="iio:device*", ATTR{name}=="accel_3d", MODE="0640", GROUP="${group}", RUN+="${openBuffer} %p"
  '';
}
