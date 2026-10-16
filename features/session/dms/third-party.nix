{ inputs, ... }:

{
  # Upstream DMS home modules, owned by this feature's own flake rather than a
  # global third-party imports file -- so deleting features/dms/ takes its whole
  # dependency surface with it.
  imports = inputs.feat-dms.homeModules;
}
