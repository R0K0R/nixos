/*
  The Nix every host runs: 2.35 (why 2.35: nixos.nix here), plus the patches
  below. A function of the package set, so the default here and the
  generic build tuning/pkgs-config.nix picks on gb4 are the same Nix.

  nix-ca-rebuild-after-gc.patch backports NixOS/nix#16477, carried until it
  merges (see the patch header for what the backport adds).
  Since 2.35 dropped the BuildTrace <-> ValidPaths foreign key, a GC keeps a
  content-addressed output's build trace after deleting the output, and a
  rebuild that is not bit-identical then fails for good:
    error: Trying to register a realisation of '...attr-...-2.6.0.drv^bin',
    but we already have another one locally.
  (yulee and victus-15, 2026-10-30, after the bump's GCs: 6883 and 7375 such
  traces, cleared by hand with sqlite.) With the patch a trace whose output is
  no longer valid is replaced by the rebuild; two differing outputs that both
  exist are still an error.

  nix-ca-stale-trace-is-unbuilt.patch is the other half: a LOOKUP of such a
  trace answers "unbuilt" instead of the deleted path, which made every build
  needing that output fail with "some outputs are unexpectedly invalid" until
  the row was deleted by hand. Not yet reproduced: GC then a LOCAL rebuild
  already recovers with the first patch alone (scratch-store test,
  2026-11-19); the failing route (likely outputs from a builder or cache)
  is untested, so keep the build-trace cleanup until it is.

  nix-ca-gc-drops-build-traces.patch removes the cause the other two cope
  with: the GC deletes a path's build traces with the path, as the dropped
  foreign key's cascade did, and a one-time migration drops the stale traces
  already there. The other two stay as the safety net. Needed beyond this
  host because harmonia serves db.sqlite directly: a stale trace on a peer
  became a substitution failure here (2026-11-26).
*/
ps:
(ps.nixVersions.nixComponents_2_35.appendPatches [
  ./nix-ca-rebuild-after-gc.patch
  ./nix-ca-stale-trace-is-unbuilt.patch
  ./nix-ca-gc-drops-build-traces.patch
]).nix-everything
