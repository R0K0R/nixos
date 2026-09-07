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
{ lib, hostRuntimeClassifier, skip }:

final: prev:
if
  builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null
  || ((prev.stdenv.hostPlatform.gcc or { }).arch or "") == ""
then
  { }
else
  let
    tunedSuffix = "x86_64-unknown-linux-gnu";

    /*
      `skip` keeps the stdenv's closure input-addressed, and that is a
      correctness requirement rather than a preference. A CA derivation's
      outPath is a PLACEHOLDER until it is built, so every reference check that
      names one gets a bogus entry: krb5 disallows `bashNonInteractive` in its
      lib output, and with bash content-addressed that entry evaluates to
      "/1lba4bnb..." and the build dies with "not a valid output of this
      derivation" (measured 2026-09-07). krb5 itself is not CA; its dependency
      was. Those packages are also the cheapest to rebuild, so CA buys least.
    */

    /*
      A reference check that names one of the derivation's OWN outputs cannot be
      content-addressed. Under CA an output path is a placeholder until the
      build finishes, so the check reads as a bogus output name and the build
      dies -- krb5's `lib` output disallows its `dev` output and fails with
      "output check for 'lib' contains output name '/1lba4bnb...', but this is
      not a valid output of this derivation" (measured on nix 2.34.8, and worse
      on 2.18.1, which called it an illegal reference specifier).

      Any non-empty reference check is skipped, which is blunter than the real
      rule -- only a check naming the derivation's OWN output breaks, and curl
      disallows a reference to bash without trouble. Inspecting the entries to
      tell those apart is not available: `toString` or even `isString` on one
      forces an output path while the package set is still being built, and
      that re-enters the splice recursion (measured). Coverage stays at roughly
      87% of candidates, so the precision is not worth the fragility.
    */
    checkKeys = [
      "allowedReferences"
      "allowedRequisites"
      "disallowedReferences"
      "disallowedRequisites"
    ];
    nonEmpty = a: lib.any (k: (a.${k} or [ ]) != [ ]) checkKeys;
    hasRefCheck =
      a: nonEmpty a || lib.any nonEmpty (lib.attrValues (a.outputChecks or { }));
    # has-attr only: it forces `prev` to WHNF and nothing more.
    candidates = builtins.filter (
      n: (prev ? ${n}) && !(builtins.elem n skip)
    ) hostRuntimeClassifier.runtimeNames;
  in
  # The eligibility test lives INSIDE the value, not in a filter. Deciding it
  # out here forces every candidate while the package set is still being built,
  # which is infinite recursion once the set is large and the packages carry a
  # derived stdenv (measured, after overlays/heavy.nix grew to the same list).
  # An ineligible or throwing name yields the untouched package instead.
  builtins.listToAttrs (
    map (n: {
      name = n;
      value =
        let
          v = prev.${n};
          t = builtins.tryEval (
            lib.isDerivation v
            && v ? overrideAttrs
            && !(v ? outputHash)
            && lib.hasInfix tunedSuffix (v.name or "")
            && !(hasRefCheck (v.drvAttrs or { }))
          );
        in
        if t.success && t.value then v.overrideAttrs (_: { __contentAddressed = true; }) else v;
    }) candidates
  )
