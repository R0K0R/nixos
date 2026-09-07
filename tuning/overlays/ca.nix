/*
  Content-addressed derivations for the TUNED host set only.

  Why selective: CA changes derivation hashes, so a CA'd package never
  substitutes from cache.nixos.org. The build-platform side (~91% of the
  toplevel closure, measured) is byte-identical to upstream and must stay
  input-addressed to keep substituting; the tuned host set never substituted
  anyway, so CA costs it nothing and buys early cutoff: rebuild a dependency,
  and if its output is byte-identical the cascade stops at the first
  unchanged dependent. That is the mass-rebuild case ccache cannot help with.

  Gate that had to pass first: bit-reproducibility. 47 tuned paths built
  independently on yulee and victus-15 (different CPUs, OSes, Nix versions)
  were 47/47 NAR-identical (2026-09-07). Caveat: that overlap skewed small; a
  webkit-scale confirmation is still owed.

  "Tuned" is decided the way upstream-tools.nix decides the inverse: a
  host-runtime name (classifier) whose derivation name carries the pseudo-cross
  suffix. Fixed-output derivations are skipped by make-derivation itself when
  outputHash is set; everything without overrideAttrs is left alone.
*/
{ lib, hostRuntimeClassifier }:

final: prev:
if
  builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null
  || ((prev.stdenv.hostPlatform.gcc or { }).arch or "") == ""
then
  { }
else
  let
    tunedSuffix = "x86_64-unknown-linux-gnu";
    candidates = builtins.filter (n: prev ? ${n}) hostRuntimeClassifier.runtimeNames;
    eligible =
      n:
      let
        t = builtins.tryEval (
          let v = prev.${n}; in
          lib.isDerivation v
          && v ? overrideAttrs
          && !(v ? outputHash)
          && lib.hasInfix tunedSuffix (v.name or "")
        );
      in
      t.success && t.value;
  in
  builtins.listToAttrs (
    map (n: {
      name = n;
      value = prev.${n}.overrideAttrs (_: { __contentAddressed = true; });
    }) (builtins.filter eligible candidates)
  )
