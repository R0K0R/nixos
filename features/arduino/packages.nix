# Serial access needs the dialout group -- granted in the host file, since
# group membership is about the machine's ports rather than the toolchain.
{ pkgs }:
{
  system = with pkgs; [
    arduino-cli
  ];
}
