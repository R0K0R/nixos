/*
  Your own home-manager modules. These are evaluated with the same arguments
  the system's feature home halves get: pkgs (the host's), lib, config,
  osConfig, hostName, inputs (the SYSTEM flake's inputs).

  homeLib.<host>.facts has plain data about the machine -- tuning levers, your
  effective registry axes -- if you need to branch on it.
*/
{ pkgs, ... }:

{
  imports = [ ];

  # home.packages = [ pkgs.hello ];
}
