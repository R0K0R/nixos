#!/usr/bin/env bash
# impermanence-prepare.sh -- on galaxybook4-pro360, BEFORE the live-USB session
# (docs/impermanence-migration.md). As the user, no sudo.
#
#   1. builds the post-migration system (flake output migration.galaxybook4-pro360)
#      -- dispatched to the builders like every build here (max-jobs 0) -- and
#      keeps it alive with an out-link, so the USB session installs it as is;
#   2. writes the plan the USB script reads, into ~/impermanence-plan/:
#        toplevel            the system's store path
#        system-dirs.txt     absolute directories persisted (environment.persistence)
#        system-files.txt    absolute files persisted
#        user-<name>.json    {directories, files} relative to the home: the user's
#                            own my.persist (home repo) + features' my.state.user +
#                            the always-kept home-manager state -- exactly what
#                            persist-home-<name> will bind at boot
#        user-<name>.persist.json   the user's own list, seeded as .persist.json
#
# usage: scripts/impermanence-prepare.sh [--no-build]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
flake=$PWD
plan=$HOME/impermanence-plan
mkdir -p "$plan"
attr=migration.galaxybook4-pro360

if [ "${1:-}" != --no-build ]; then
  echo "== building $attr (on the builders)"
  nix build "$flake#$attr.config.system.build.toplevel" --out-link "$plan/system"
fi
readlink -f "$plan/system" >"$plan/toplevel" 2>/dev/null || echo "(not built: --no-build)" >"$plan/toplevel"

echo "== system persistence"
nix eval --raw "$flake#$attr.config.environment.persistence" --apply '
  p: builtins.concatStringsSep "\n" (map (d: d.directory) p."/persist".directories) + "\n"' >"$plan/system-dirs.txt"
nix eval --raw "$flake#$attr.config.environment.persistence" --apply '
  p: builtins.concatStringsSep "\n" (map (f: f.file) p."/persist".files) + "\n"' >"$plan/system-files.txt"

for u in $(nix eval --raw "$flake#$attr.config.my.users" --apply 'us: builtins.concatStringsSep " " (builtins.attrNames (builtins.removeAttrs us [ ]))'); do
  imp=$(nix eval --raw "$flake#$attr.config.my.users.$u.impermanentHome" --apply 'b: if b then "1" else "0"')
  [ "$imp" = 1 ] || { echo "== $u: persistent home (bound whole)"; continue; }
  echo "== $u"
  # the user's own list, from their home repo (r0k0r: ~/config/home)
  repo=${HM_REPO:-$HOME/config/home}
  nix eval --json --override-input system "git+file://$flake" \
    "$repo#homeConfigurations.\"$u@galaxybook4-pro360\".config.my.persist" >"$plan/user-$u.persist.json"
  # + what the system adds (features' my.state.user + home-manager state)
  nix eval --json "$flake#$attr.config.my.impermanence.userState" >"$plan/user-$u.system.json"
  jq -s '{directories: ((.[0].directories // []) + (.[1].directories // []) | unique),
          files: ((.[0].files // []) + (.[1].files // []) | unique)}' \
    "$plan/user-$u.persist.json" "$plan/user-$u.system.json" >"$plan/user-$u.json"
  # the same entries one per line: the live USB may have no jq
  jq -r '.directories[], .files[]' "$plan/user-$u.json" >"$plan/user-$u.paths.txt"
  echo "   $(jq '.directories|length' "$plan/user-$u.json") directories, $(jq '.files|length' "$plan/user-$u.json") files"
done
echo "plan written to $plan -- the USB session reads it from the old /home"
