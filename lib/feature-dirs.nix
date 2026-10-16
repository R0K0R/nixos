/*
  features/ -> the list of feature directories, walked recursively.

  A directory holding nixos.nix or home.nix IS a feature, and the walk stops
  there: a feature owns everything below it (dms/plugins/, niri's patched
  sub-flake, ...), and none of that is a module. A directory holding neither
  is a CATEGORY, and the walk descends into its subdirectories, so a feature
  may live at features/<category>/<feature>/ (or deeper). Loose files in a
  category -- a README -- are ignored.

  A directory that is neither (no module, no subdirectory) is an error, not
  silently skipped. "Nothing may live under features/ that is not a real
  module" (flake.nix) used to be enforced by every directory BEING a feature;
  with categories, an empty or misspelt one would otherwise just vanish --
  the same silent omission the readDir walk exists to rule out.

  `name` is the leaf directory name, which is what my.<name> and the
  per-feature files (packages.nix) are keyed by. Two features with the same
  leaf name in different categories would collide on that option, so that is
  an error too.

  Shared by flake.nix (module collection) and tuning/runtime-cache/lookup.nix
  (Tier 3 anchors from each feature's packages.nix). They used to each run
  their own top-level readDir, and a nested feature seen by one walk and not
  the other would have its packages silently classified not-host-runtime.

  ORDER: depth-first, alphabetical at every level -- for today's flat tree
  exactly `attrNames (readDir ./features)`. List-typed options concatenate in
  this order (see features/dms/compositor.nix on why dms/hyprland need explicit
  mkBefore/mkAfter), so moving a feature into a category can reorder such
  lists; check with a drv comparison when moving.
*/
root:

let
  walk =
    rel: dir:
    let
      entries = builtins.readDir dir;
      isFeature = entries ? "nixos.nix" || entries ? "home.nix";
      subdirs = builtins.filter (n: entries.${n} == "directory") (builtins.attrNames entries);
    in
    if isFeature then
      [
        {
          name = baseNameOf rel;
          path = dir;
          inherit rel;
        }
      ]
    else if subdirs == [ ] then
      throw ''
        features/${rel}: neither a feature (no nixos.nix or home.nix) nor a category
        (no subdirectories). Nothing may live under features/ that is not a module.''
    else
      builtins.concatMap (n: walk (if rel == "" then n else "${rel}/${n}") (dir + "/${n}")) subdirs;

  found = walk "" root;

  byName = builtins.groupBy (f: f.name) found;
  dups = builtins.filter (n: builtins.length byName.${n} > 1) (builtins.attrNames byName);
in
if dups == [ ] then
  found
else
  throw (
    "features/: leaf names must be unique (they are the my.<name> option): "
    + builtins.concatStringsSep "; " (
      map (n: "${n} at " + builtins.concatStringsSep ", " (map (f: "features/${f.rel}") byName.${n})) dups
    )
  )
