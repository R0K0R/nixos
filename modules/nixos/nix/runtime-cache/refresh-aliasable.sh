#!/usr/bin/env bash
# Caches the expensive part of upstream-tools-overlay.nix's substitution
# decision: which top-level nixpkgs attributes are structurally safe to
# alias to nixpkgs-upstream at all (exist as derivations in both trees,
# aren't target-aware toolchain tools, aren't hand-excluded platform
# machinery). This is host-independent -- it doesn't touch
# hostRuntimeClassifier -- so one cache file covers both hosts. Refreshed
# manually, not per-rebuild:
#   ./refresh-aliasable.sh
# Measured cost of NOT caching this: recomputing it on every eval (fork +
# upstream imports, then a tryEval-guarded isDerivation/targetPrefix check
# over all ~27683 top-level attributes) accounted for most of a ~44s cost in
# `environment.systemPackages` evaluation.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"

NIXPKGS_REV="$(jq -r '.nodes.nixpkgs.locked.rev' "$FLAKE_ROOT/flake.lock")"
NIXPKGS_NARHASH="$(jq -r '.nodes.nixpkgs.locked.narHash' "$FLAKE_ROOT/flake.lock")"
CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

OUT="$FLAKE_ROOT/modules/nixos/nix/runtime-cache/aliasable.nix"

echo "computing structurally-aliasable package names (fork+upstream imports, full attribute walk, ~30-45s)..."
nix eval --impure --expr "
  let
    inputs = (builtins.getFlake \"$FLAKE_ROOT\").inputs;
    lib = inputs.nixpkgs.lib;
    fork = import inputs.nixpkgs { system = \"x86_64-linux\"; config.allowUnfree = true; };
    upstream = import inputs.nixpkgs-upstream { system = \"x86_64-linux\"; config.allowUnfree = true; };

    isDrvIn = set: n:
      let r = builtins.tryEval (lib.isDerivation (set.\${n} or null));
      in r.success && r.value;

    lower = lib.toLower;

    isTargetAware = n:
      let r = builtins.tryEval ((fork.\${n}.targetPrefix or null) != null);
      in r.success && r.value;

    excludePatterns = [ \"stdenv\" \"emulatorhook\" ];
    excludeNames = [
      \"coreutils\" \"findutils\" \"diffutils\" \"gnused\" \"gnugrep\" \"gawk\" \"gnutar\"
      \"gzip\" \"bzip2\" \"gnumake\" \"bash\" \"patch\" \"xz\" \"file\" \"patchelf\"
    ];

    structurallyKeepable = n:
      !(builtins.elem n excludeNames)
      && !(lib.any (p: lib.hasInfix p (lower n)) excludePatterns)
      && isDrvIn fork n
      && isDrvIn upstream n
      && !(isTargetAware n);
  in
  {
    nixpkgsNarHash = \"$NIXPKGS_NARHASH\";
    nixpkgsRev = \"$NIXPKGS_REV\";
    capturedAt = \"$CAPTURED_AT\";
    names = builtins.filter structurallyKeepable (builtins.attrNames fork);
  }
" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
if command -v nixfmt >/dev/null 2>&1; then
  nixfmt "$OUT"
fi

echo "wrote $OUT"
