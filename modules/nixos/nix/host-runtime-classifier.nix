/*
  Thin wrapper preserving the old interface (isHostRuntime, runtimeNames)
  consumed by o3-overlay.nix and gentoo-lto-overlay.nix. The actual
  three-tier lookup logic lives in runtime-cache/lookup.nix -- see that
  file's header for the full design.
*/
{
  inputs,
  system,
  host,
}:
import ./runtime-cache/lookup.nix { inherit inputs system host; }
