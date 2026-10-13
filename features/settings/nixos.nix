{ lib, ... }:
{
  # The unified settings system: the hearth engine (generic store + change-diff signal) fed by a
  # schema that features/settings assembles from every feature's own `settings.nix` fragment. See
  # SETTINGS.md for the design. The schema generation + runtime wiring live in home.nix; this just
  # declares the on/off switch (read via osConfig in home.nix).
  options.my.settings.enable = lib.mkEnableOption
    "the unified hearth settings store (generated schema.json + runtime settings.json + change signal)";
}
