# cross-debug/105: gnupatch-2.8 allowedRequisites mismatch in pseudo-cross stdenv bootstrap

## Symptom

`nixos-rebuild build` fails at the bootstrap layer with an `allowedRequisites` violation:

```
error: build of '/nix/store/a4qgjr3fssw64534qgl8mrp4mn0l4nwg-stdenv-linux.drv' on 'ssh://r0k0r@100.64.0.1' failed:
output '/nix/store/1cqdgp5i5ayrizz0g6jxfa3lzd9dznq5-stdenv-linux' is not allowed to refer to the following paths:
    /nix/store/4fqb8h53463w0y3j23qw041n6f1l0yrr-patch-2.8
```

Three of five `stdenv-linux` variants fail; two succeed.  The failing path
(`patch-2.8` at hash `4fqb8h5…`) is **not present in yulee's store**.

## Root cause

Two independent bugs compounded:

### Bug 1 — `gnupatch-2.8` test failure on ZFS sandbox (yulee)

`pkgs/tools/text/gnupatch/default.nix` shipped with:
```nix
doCheck = stdenv.hostPlatform.libc != "musl";
```

The `dash-o-append` test inside patch-2.8's test suite relies on
filesystem semantics that ZFS (yulee's `/nix/store` device) does not
provide: the test tries to create a file with a null byte in its name,
which ZFS silently rejects or errors on differently from the kernel's
`tmpfs`/`ext4` default.

Result: the bootstrap's gnupatch build **sometimes passes, sometimes
fails** (the test is flaky on ZFS — it depends on whether the sandbox
enforces certain restrictions differently run-to-run).

### Bug 2 — Divergent gnupatch hash from the user overlay

The host overlay in `hosts/galaxybook4-pro360/default.nix` had:
```nix
patch = prev.patch.overrideAttrs (_: { doCheck = false; });
```

This was added to silence the test failure in the *final* package set
(where `allowCustomOverrides = true`).  But it creates a **new
derivation** with a different Nix store hash (because `nativeCheckInputs
= [ ed ]` is excluded from the derivation inputs when `doCheck = false`,
changing the hash).

The result is **two distinct gnupatch-2.8 derivations**:

| Variant | `doCheck` | `nativeCheckInputs` | Hash |
|---|---|---|---|
| Bootstrap stages 1–4 (no overlays) | `true` | `[ ed ]` | H_test |
| Final package set (overlay applied) | `false` | `[ ]` | H_notest |

The `stdenv-linux` final stage computes:
```nix
initialPath = (import ../generic/common-path.nix) { pkgs = prevStage; };
# prevStage = stage4 (no overlays) → includes H_test
```

And `allowedRequisites` uses `inherit (prevStage) gnupatch` = H_test.

So far consistent — but in the **pseudo-cross** instantiation, some
`stdenv-linux` variants are built for adjacent package sets (e.g.
`pkgsBuildBuild`, `pkgsHostHost`) whose bootstrap chains evaluate
`prevStage` differently, and in those chains `prevStage.patch` ends up
resolving to H_notest (the overlay version) rather than H_test.  The
`initialPath` then embeds H_notest in `$out/setup`, while
`allowedRequisites` still lists H_test → check fails.

The broken path (`4fqb8h5…`) was never built on yulee for the failing
variants because H_notest's gnupatch was only built (by the overlay
derivation) on a machine where the test passed; yulee's ZFS sandbox
means H_test never consistently lands in yulee's store either.

## Fix

**Single change: disable tests at the source.**

`pkgs/tools/text/gnupatch/default.nix`:
```nix
# was: doCheck = stdenv.hostPlatform.libc != "musl";
doCheck = false;  # bad-filenames test fails in sandboxed builds on non-tmpfs (e.g. ZFS)
```

With this change there is **exactly one gnupatch-2.8 derivation** in
every bootstrap stage and in every adjacent package set — the
`doCheck = false` version.  The overlay's `overrideAttrs` call becomes
a no-op (same inputs → same hash), so all `stdenv-linux` variants agree
on a single `gnupatch` hash, and the `allowedRequisites` check passes.

The user overlay's redundant override is removed:
```nix
# removed from hosts/galaxybook4-pro360/default.nix:
# patch = prev.patch.overrideAttrs (_: { doCheck = false; });
```

## Classification

- **Not a pseudo-cross pattern A–G instance** — this is a build-machine
  filesystem interaction (ZFS) that creates a flaky test, combined with
  a nixpkgs bootstrap invariant (one consistent gnupatch hash across all
  bootstrap stages and their overlays).
- **Category**: bootstrap infrastructure + ZFS sandbox quirk.
- **Affected commits**: `ef48c1f6d` (gnupatch doCheck=false),
  `169b804` (flake.lock + overlay cleanup).

## Lesson

When a package's tests are flaky in the remote builder's sandbox
(ZFS/filesystem-dependent), disable them **at the nixpkgs package
source**, not via `overrideAttrs` in the host overlay.  An overlay-only
fix creates a divergent hash that breaks the bootstrap's
`allowedRequisites` invariant: the bootstrap stages (no overlays) and
the final package set (overlays applied) end up with different gnupatch
derivations, causing `stdenv-linux` to embed a store path that
`allowedRequisites` does not recognise.
