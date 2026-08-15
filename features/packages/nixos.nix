{ lib, ... }:

{
  /*
    Interim home: the package machinery is still the old hostname-keyed
    user-packages.nix. This option exists so the two home configs could collapse
    into one without silently handing a headless host the `homeManager.common`
    list it never had.

    The packages rework replaces all of this with a packages.nix per feature,
    read by that feature's own nixos.nix, plus my.packages.extra in the host
    file for genuine one-offs.
  */
  options.my.packages.homeManager.enable =
    lib.mkEnableOption "the shared home-manager package list (interim, hostname-keyed)";
}
