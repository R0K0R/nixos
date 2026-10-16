/*
  Is `prev` the package set that o3.nix / gentoo-lto.nix should tune? One
  predicate, shared by both overlays and by upstream-tools.nix's native branch,
  so the three can never disagree about which set is "the host".

  WITH MARCH (native = false) the answer is what it always was: the set whose
  hostPlatform carries gcc.arch. The IntraISACross split makes that exactly the
  host splice -- pkgsBuildHost, pkgsMusl, pkgsi686Linux and the bootstrap
  stages all lack gcc.arch. Real hosts take this branch, and it is written to
  evaluate the identical expression the overlays used inline before, so their
  derivations do not move.

  WITHOUT MARCH (native = true) no set carries gcc.arch, so that test would
  skip everything: the overlays used to be inert there, and tuning/nixos.nix
  asserted march to say so. The set to tune is then the ONE native glibc
  x86_64 set -- hostPlatform == buildPlatform -- and nothing else nixpkgs
  instantiates alongside it:

    pkgs (main)        x86_64 gnu -> x86_64 gnu   equal       <- tuned
    pkgsi686Linux      i686   gnu -> x86_64 gnu   differ
    pkgsMusl           x86_64 musl -> x86_64 gnu  differ
    pkgsStatic         isStatic                   excluded explicitly
    pkgsLLVM etc.      useLLVM/linker attrs       differ

  pkgsStatic is excluded by name for the same reason upstream-tools.nix gives:
  it can compare equal on everything the test looks at and is still a
  different, statically linked world.

  `config.tuningNativeBaseline` marks the untuned copy of this host's package
  set that tuning/nixos.nix builds as the alias target for build tools. It
  carries the same overlay list (these overlays included), so they must turn
  themselves off inside it, or the baseline would be tuned too.

  What this predicate does NOT do is keep build tools untuned. Natively the
  build tools ARE this set (pkgsBuildHost == pkgs), so tuning openssl here also
  moves curl, git and python3 as build inputs. That is the job of
  tuning/native-build-tools.nix (libraries a build tool links stay untuned)
  and upstream-tools.nix's NATIVE MODE branch (everything not host-runtime
  aliased back to the untuned baseline), both wired in by tuning/nixos.nix
  whenever o3 or lto is on without march.
*/
{ native, prev }:
let
  hp = prev.stdenv.hostPlatform;
in
if native then
  !(prev.config.tuningNativeBaseline or false)
  && hp == prev.stdenv.buildPlatform
  && hp.system == "x86_64-linux"
  && (hp.isGnu or false)
  && !(hp.isStatic or false)
else
  ((hp.gcc or { }).arch or "") != ""
