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

# Resolved via builtins.getFlake's own .inputs.nixpkgs, not a raw jq lookup of
# flake.lock's "nixpkgs" JSON key -- see refresh-tier1.sh for why that key is
# no longer reliable (nix-doom-emacs-unstraightened's own "nixpkgs" input
# collides with this repo's node name once locked).
NIXPKGS_INFO="$(
  nix eval --impure --json --expr "
    let f = builtins.getFlake \"$FLAKE_ROOT\";
    in { inherit (f.inputs.nixpkgs) rev narHash; }
  "
)"
NIXPKGS_REV="$(jq -r '.rev' <<<"$NIXPKGS_INFO")"
NIXPKGS_NARHASH="$(jq -r '.narHash' <<<"$NIXPKGS_INFO")"
CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

OUT="$FLAKE_ROOT/tuning/runtime-cache/aliasable.nix"

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

    keepable = builtins.filter structurallyKeepable (builtins.attrNames fork);

    /*
      Attribute name -> pname, recorded ONLY where the two differ.

      Every runtime-cache tier records PNAMES: refresh-tier1.sh reads pname from
      each store path's own deriver (deliberately -- see its own comment), and
      tier2/tier3 key their genericClosure on p.pname. But every CONSUMER asks
      by TOP-LEVEL ATTRIBUTE NAME: upstream-tools.nix walks the names list
      below, o3.nix and gentoo-lto.nix filter their own attribute lists.

      Where the two coincide nobody notices. Where they do not, the classifier
      holds the right answer under a key nothing ever looks up -- pandoc is
      recorded as pandoc-cli, so isHostRuntime on the attribute returned false
      and upstream-tools aliased a genuinely host-runtime package to an untuned
      upstream build. Measured at 490 such attributes against this host tier1.

      Recorded here rather than in the tier files because this walk already
      visits every attribute, so it costs nothing extra, and because one map
      fixes all three tiers at once instead of each having to capture its own.
    */
    pnameOf = n:
      let r = builtins.tryEval (fork.\${n}.pname or null);
      in if r.success then r.value else null;
  in
  {
    nixpkgsNarHash = \"$NIXPKGS_NARHASH\";
    nixpkgsRev = \"$NIXPKGS_REV\";
    capturedAt = \"$CAPTURED_AT\";
    names = keepable;
    pnames = lib.listToAttrs (
      builtins.concatMap (
        n:
        let pn = pnameOf n;
        in if pn != null && pn != n then [ (lib.nameValuePair n pn) ] else [ ]
      ) keepable
    );
  }
" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
if command -v nixfmt >/dev/null 2>&1; then
  nixfmt "$OUT"
fi

echo "wrote $OUT"
