/*
  The Nix every host runs: 2.35 (why 2.35: nixos.nix here), plus the one
  patch below. A function of the package set, so the default here and the
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
*/
ps: (ps.nixVersions.nixComponents_2_35.appendPatches [ ./nix-ca-rebuild-after-gc.patch ]).nix-everything
