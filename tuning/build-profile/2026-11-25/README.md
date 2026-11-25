# Build profile: the 2026-11-24/25 world rebuild

A reference for sizing the next nixpkgs rebase: what each world consists of,
and roughly what had to be built. The closures don't change dramatically
between rebuilds, so these numbers plus the heavy-hitter list give a decent
ETA up front.

Revisions: /etc/nixos main at `0d08c3b` nixpkgs (fork `combined-2026-11-23`,
rebased onto nixos-unstable `2786a2a7`); home at `0346de7` (relocked to the
0.57.2 world, keystone `3d2e050`).

## Files

- `gb4-system.tsv`, `victus-system.tsv`, `gb4-home.tsv` list the full
  derivation closure of each world, one line per derivation:
  `name<TAB>tuned|native<TAB>built|-`.
  - `tuned`: the name carries the IntraISACross `x86_64-unknown-linux-gnu`
    suffix.
  - `built`: a derivation of that name was built in this round, in any of
    the three worlds (from the `building '...'` lines of the build logs).

## Summary

| world | drvs | tuned | native | tuned built | native "built" |
|---|---:|---:|---:|---:|---:|
| gb4 system | 12,183 | 1,268 | 10,915 | 1,250 | 5,454* |
| victus system | 10,280 | 759 | 9,521 | 757 | 5,006* |
| gb4 home | 20,284 | 2,470 | 17,814 | 2,225 | 7,520* |

\* Overcounted. The match is by name across all three worlds' logs, and a
native derivation has the same name on every host, so one native build marks
it built everywhere. Content-addressed builds can also log the resolved
derivation. The tuned columns are reliable, since tuned names are host-specific.
A rebase rebuilds essentially the whole tuned set: 1,250 of 1,268 on gb4,
757 of 759 on victus.

## Heavy hitters (the critical path, in practice)

Each is 1 to 3+ hours on one builder, and none can be split:

- qtwebengine (Chromium) and webkitgtk (two builds)
- the tuned dotnet-vmr, the whole .NET SDK from source, plus a stage0 SDK
  (pulled in by galaxy-buds-client)
- llvm/clang (several versions), ghc, libreoffice, the kernel, opencv,
  qtbase/qtdeclarative, mesa, rustc
- the fork's native stdenv bootstrap (bootstrap-stage1..4 gcc/binutils):
  it isn't substitutable because of fork commit af54604. See the next-rebase
  notes in the Claude memory.

## Wall time, this round

- victus system: ~10:30 on 11-24 to 22:17 (with three restarts: kbd/e2fsprogs
  output checks, filelock, a haddock deadlock).
- gb4 system: 01:28 to 05:11 on 11-25, then 08:46 after 6 fixes.
- gb4 home: from 08:57, in five passes plus the yulee-local run from 13:40,
  still running at 20:00.
  - Inflated by a GC that removed tuned build inputs (don't do that again:
    root the newest worlds' .drv closures and GC with keep-outputs).
  - Inflated by gb4's Wi-Fi roaming between KSA APs, which killed every
    in-flight remote build. Orchestrate long builds from a host that doesn't
    roam.
