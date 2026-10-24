# Multi-user design

The agreed target for splitting this flake into an admin-owned system flake and
per-user standalone home-manager repos, worked out 2026-10-16/17. This is the
reference: what the design is, why each part has the shape it has, what was
considered and rejected, what is deliberately out of scope, and where the
implementation stands. The README describes what exists; this describes where
it is going.

## Goal

Real multi-user encapsulation with idiomatic, independent rollback. A user
should be able to change and roll back their own environment without the admin
and without being able to affect the system or other users, and the admin
should be able to change the system without silently breaking a user's home.

## The two repos

**System flake** (this repo; eventually a real directory at `/etc/nixos`,
admin-writable, user-readable; GitHub read role for users). It holds hardware,
boot, the nix daemon and builders, the singletons, the user registry and types,
and the optional tuning backend. It uses **one nixpkgs** for everything -- the
fork only when tuning's `march` lever needs it. Something newer than that pin is
a self-written derivation or a feature, not a second nixpkgs. An alternate
nixpkgs is allowed only through a lock-check allowlist with a declared reason,
for something isolated (a CLI tool), never for anything loaded into a shared
process (GL, plugins).

It exports `homeLib.<host> = { pkgs; modules; facts; mkHome; ... }`.

**User repos** (`~/config/home`, e.g. `github:R0K0R/home`): standalone
home-manager, consuming `homeLib.<host>`. They pin no nixpkgs and no
home-manager. Users are **untrusted** in the nix daemon (not in
`trusted-users`); the admin does admin things through sudo, not through daemon
trust.

Why one nixpkgs: on an IntraISACross host a second nixpkgs is a second package
set, untuned, with its own glibc and systemd -- everything rebuilt, and two
copies of every singleton loaded side by side. A home built against the host's
own `pkgs` reuses the system's store paths. One pin does not mean one package
set: a user may choose their own tuning, which instantiates the SAME pin
differently (see [Per-user tuning](#per-user-tuning)).

## Singletons and the epoch

Some components are shared by every session and must match what the user's
generation was built against: glibc, the kernel, systemd, dbus, polkit, nix,
greetd, the locker (and on victus the NVIDIA driver). The **epoch** is a hash of
that singleton set's **drv paths** -- not output paths, because with CA
derivations outputs are unknown before the build.

- A boot unit (not activation, which can be skipped or repeated) appends
  `{ rev, epoch, generation }` to `/var/lib/nixos-epochs/history.json`, which
  must be persisted.
- Rolling a home back within an epoch is free. Across epochs it needs a system
  rollback too.
- Surface shrink: the fewer singletons, the rarer epoch changes. galaxybook can
  reach zero in-process system code (empty epoch); NVIDIA is victus's only
  epoch member. `/run/opengl-driver` is RUNPATH-baked, so it is mapped per user
  in a mount namespace rather than being a singleton (features/session/
  gl-namespace, Done 14). It stays in the epoch while anyone -- an unmapped
  user, the greeter, the fallback session -- loads the system's tree.

### Where checks are enforced

- **User side, advisory only**: the `hm-switch` wrapper (pre-eval lookup of the
  epoch history), the lock check, an activation check. A user may deliberately
  run `home-manager switch` or relock, and that is their right; these checks
  inform, they do not gate.
- **System side, enforced**: greetd reads `$generation/epoch` as data. A
  mismatch gets the **fallback session** by default, with an explicit "start
  anyway".
- **Fallback session**: cage + the system's kitty + a banner explaining the
  mismatch, with Claude Code available as a system package and the situation
  as its first message. A user's first login (no generation yet) also gets the
  fallback session and an empty persistence manifest.

Implemented as (Done 14, on for galaxybook4-pro360): the hashed set is not a
hand-kept singleton list but the computed **surface** (`lib/epoch.nix`, see
[Surface compatibility](#surface-compatibility)): the system derivations
loaded INTO user processes -- session-environment plugin paths, the graphics
driver, PAM and NSS modules, the locale archive. glibc, systemd and the
locker's PAM modules enter through it; the kernel, dbus, polkit, nix and
greetd are reached over protocols and are not hashed (a change there needs no
home rebuild). The history is JSON lines, `/var/lib/nixos-epochs/history.jsonl`.
greetd has no session wrapper, so the guard is in the session entries every
greeter reads: the `desktops` aggregate is rebuilt with each Exec= behind
`guarded-session`, plus "<Name> (ignore epoch)" entries for "start anyway".

## Impermanence fit

- Persistence is a **per-user manifest** (data, `persist.nix` in the user
  repo), mounted by a system unit at boot, independent of whether the user's
  generation is valid. The manifest is validated system-side.
- No manifest: refuse login. First login gets an empty manifest + fallback.
- A boot re-activation unit for standalone home-manager (the home is wiped, the
  generation is not).
- `~/.local/state/{nix,home-manager}` are always persisted, or rollback has
  nothing to roll back to.

## Builders

Builder access is per user **class**, not per user: extra nix-daemon instances
on the same store, each with its own `nix.conf`, socket, builder list and ssh
key. The default daemon's `allowed-users` = root + admin. Class daemons, stores
and keys exist only for classes that have real users. The user registry and the
host user lists are flake-level plain data precisely so every host -- builders
included -- can derive them without evaluating any other host.

Implemented as features/nix/class-daemons (off; see Done 12). Decisions made
while implementing it:

- **A class is a registry type.** Members are the host's accounts of that type
  with daemon access (nix = untrusted or admin).
- **Members stay untrusted on their class daemon.** Nix cannot trust a client
  for `builders` alone: a trusted client can import unsigned paths, register
  realisations, disable sandbox/require-sigs per connection and set hooks the
  daemon runs as root -- on a store everyone shares. So builder *choice* is a
  socket choice: each class gets a `default` daemon (its builders, the host's
  max-jobs), one daemon per builder that builds only there, and optionally a
  `local` one. `trusted = true` exists per class but is accepted only when
  every member is already nix = admin: a class daemon moves trust, never widens
  it.
- **The class key is the real builder ACL.** The class daemon runs ssh with
  `-F` its own ssh_config (otherwise root's `Match localuser root`
  IdentityFile would offer the host builder key too); a peer that does not
  accept the class key is not reachable from that class.
- **Routing** is NIX_REMOTE from the shells' common init and a systemd user
  environment generator, only when unset and only when the socket is writable
  (a session older than the group membership would otherwise get EACCES).
  pam_env cannot condition per user; ~/.config/nix is the user's file.
- `restrictDefault` (the "default daemon: root + admin" half) exists, off: an
  unrouted process of a member (a system unit with User=, an old session)
  would lose the store instead of falling back.

## Trust and guest stores

**Sharing a store is sharing trust.** Anything a guest can write and the admin
later reads is an injection path. So:

- Guest sandboxes get **no writable shared state**: the admin ccache is
  read-only to them at most; `extra-sandbox-paths` is audited; `sandbox = true`
  everywhere.
- No setuid wrapper may have `/run/opengl-driver` in its RUNPATH (asserted).
  Implemented with gl-namespace: an evaluation assertion over the privileged
  wrappers' derivations and declared inputs, and the build-time check
  `setuidGlChecks.<host>` over their runtime closures (RUNPATH, baked dlopen
  directories, GL packages by name). Hyprland's cap_sys_nice wrapper fails
  both.

**Guest overlay store** (supersedes the guest-store / salting / signature ideas
below). Each guest gets a `local-overlay-store` on **every** machine, builders
included:

- lower = the admin `/nix/store`, read-only -- concretely a **frozen read-only
  btrfs snapshot of `@nix`** (store + db, opened as `read-only-local-store`),
  rebased at boot, at most two snapshots alive;
- upper = `/var/lib/nix-guests/<user>/upper`, one `@guests/<user>` subvolume per
  guest with a qgroup quota;
- `/nix/store` remapped in the guest's per-user mount namespace, with a
  persistent namespace handle in `/run/guest-ns/<user>/mnt`;
- on rebase: copy up paths the upper needs that the new lower lacks, and drop
  upper paths that collide with the new lower;
- **no root inside guest namespaces**: `/run/wrappers` mounted nosuid there,
  `guest-exec` drops to the guest uid.

Because the overlay is private, a guest may be *trusted inside it*, so the
transparent build hook works -- remote builds and IntraISACross included --
without a Nix patch. Open questions: the store type is experimental; admin GC
must treat guest closures as roots; the lower store changing underneath a live
overlay.

## Rejected alternatives

| alternative | why rejected |
|---|---|
| Signed build records + a Nix patch (the daemon signs realisations of trusted clients' builds; trusted clients resolve only signed ones, so guest-built CA records are ignored) | needs a local Nix patch (today a daemon trusts its own build-trace rows unconditionally), and does nothing for input-addressed paths |
| Salting guest derivations (an unused `__guestSalt` on every drv outside a published admin-built set, so guest records/paths never collide with admin ones) | needs a ~20k-drv published set per release and a double evaluation, and still leaves remote input-addressed guest builds needing trust on the builder; the per-guest overlay store isolates more with plain Nix behaviour |
| Wrapper-only remote builds (guests build via `--store ssh-ng://` + copy back, untrusted) | the normal workflow would depend on a wrapper; the overlay store keeps the transparent build hook |
| A separate guest store on the builder only | results come back into the user machine's shared store, where a key cannot be scoped to path names, so forged paths still reach the admin |
| A separately pinned, untuned singleton layer | the singletons would lose tuning, or a second tuned toolchain would be needed; a single nixpkgs makes the separate pin unnecessary |
| Per-user `tuning.json` with add-only package lists per lever | the user's real home (closure + evaluation) is better evidence than a hand list, and the set choice belongs in the home's own options |
| Leaf-only per-user tuning (`pkgs // { foo = tuned foo; }`) | users want to choose their whole set, march included, untuned as well as tuned |
| Classifier caches in the flake, written by the system only | the system cannot see a user repo's own modules; users could not contribute evidence and root could not refresh it for them |
| Reading the cache with `--impure` | evaluation would depend on machine state, and the eval worker would not see another host's files; a locked input is reproducible |
| One cache repo (git, GitHub) for all hosts | not needed: per-host plain directories plus gather/relock/distribute do the same without another repo |
| Root evaluating user repos as root | a user's flake.lock can name root-only paths, which would land in the world-readable store; refreshes run as the user |
| Two nixpkgs pins with the singletons' stdenv grafted onto the newer one | grafting stdenv across nixpkgs revisions is fragile; single nixpkgs instead, and anything newer is a self-written derivation or a feature |

## User types

A type is a preset over five axes, plus the list of axes a user of that type may
override:

| axis | values |
|---|---|
| home | persistent / tmpfs / impermanent |
| nix | none / overlay / untrusted / admin |
| session | home-manager / system-default / kiosk |
| builders | bool |
| grants | sudo, network, media, serial, input |

Presets: **admin**, **member**, **untrusted**, **handover** (tmpfs home + kiosk:
a machine lent to someone). Hosts may narrow a user's axes, never widen them.
The deployed type is recorded, and dangerous transitions (e.g. persistent to
tmpfs) need an explicit `acceptTypeChange`. uids are never reused: removed
users stay in the registry as tombstones.

Features other hosts depend on (guest-overlay, btrfs-layout, builder role) are
declared as data in `registry/hosts.nix` and asserted by each host against its
own switches.

Planned occupants: a handover guest on galaxybook; benjamin (Nix user, fish) on
galaxybook and victus.

## Everything optional

Each piece is its own feature with `_meta` requires, and all-off is plain NixOS
on upstream nixpkgs:

- **btrfs-layout**
- **impermanence** -- requires btrfs-layout
- **guest-overlay** -- requires btrfs-layout
- **ccache** -- client half consumed only by tuning's heavy overlay; builder half standalone
- **ca-derivations** -- the "tuned" package policy asserts march
- **luks** -- TPM2 unlock, **no PIN** (the user's choice); requires nothing
- **tuning** -- three independent levers, all default off:
  - `march` -- the only one needing the fork (and SDE Emacs where builders
    cannot run the target), decided pre-eval;
  - `lto`, `o3` -- independent of march. Without it they tune the native
    package set on upstream nixpkgs, skipping libraries a build tool links
    and keeping everything not host-runtime at its untuned derivation.
  Per user: the home option `my.tuning` picks the levers of that user's own
  package set, and every user's home feeds the host's classifier cache -- see
  [Per-user tuning](#per-user-tuning). (This replaces the earlier per-user
  `tuning.json` with add-only package lists.)

## Per-user tuning

Agreed 2026-10-17, implemented 2026-10-18 (evaluation only, nothing built):
`lib/home-tuning.nix` (the home option), `lib/user-tuning.nix` (the set),
`lib/surface-check.nix` (the check), `tuning/candidates.nix` + the
`my.tuning.{o3,lto}.{candidates,exclude}` options, the per-host cache inputs,
`tuning-refresh`, `scripts/tuning-cache-{migrate,relock}.sh`;
`tests/user-tuning-eval.sh`, `tests/user-tuning-scripts.sh`. Made ready to
run 2026-10-24 (reviewed against impermanence, /etc/nixos and untrusted
users; dry runs and the post-migration evaluation done, see [Running the
migration](#running-the-migration)). The caches are still in the repo: the
migration to /var/lib/tuning-cache needs root on each host.

### Each user picks their package set

A home option, defined in the user's own modules (any of them, per host as
they like):

```nix
my.tuning = { march = "system"; lto = false; o3 = true; };
```

Each lever is `"system"` (default: whatever the host does), `true` or
`false`; `march` may also be a gcc arch string, required for `true` on a host
with no march of its own. All `"system"` is the host's own `pkgs` -- every
existing home is unchanged. All `false` is plain upstream nixpkgs, which
substitutes from cache.nixos.org even on a tuned host; a tuned choice on an
untuned host is just as allowed.

Mechanism: `homeLib.<host>.mkHome` defines `_module.args.pkgs = pkgsFor
config.my.tuning`, overriding home-manager's mkDefault -- the pattern
home-manager's own nixpkgs module uses. `pkgsFor` is the host's set as the
eval matrix builds its variants: the REAL host file through mkHostWith with
the three levers forced, everything else (hardware and feature overlays,
ccache/heavy, CA -- minus CA's "tuned" policy without march) the host's.
Without march the levers that exist only for the IntraISACross split go too;
march on a host without one turns on intraISACross and upstreamTools. A
choice equal to the host's returns the host's `pkgs` value itself.

- `my.tuning` definitions must be literals and must not read `pkgs` (the set
  depends on them): infinite recursion otherwise, as with home-manager's
  nixpkgs module and the host files' raw-imported tuning.
- Still ONE pin: the fork is upstream plus patches at the same revision, so
  every library is the same version as the system's; mixing with in-process
  system code relies on the loader reusing an already-loaded soname. The
  risk is fork patches that change an ABI (qtPatches): a system Qt plugin
  built against patched qtbase inside a user's upstream Qt. That is CHECKED,
  not accepted -- see [Surface compatibility](#surface-compatibility).
- Singleton services (daemon, dbus, polkit, logind, greetd, portals, the
  compositor) always run from the system's set; users talk to them over
  protocols. In-process plugins of a system service (Hyprland plugins) must
  come from the system's set, never a user's.
- Cost: a choice different from the host's is a set the system has not
  built. The daemon builds it (system builders; overlay guests their own).
  Accepted: admins stop what takes too long.
- One extra full evaluation of the host per distinct choice.
- Integrated homes (`homeActivation = "system"`) follow the system; per-user
  tuning is for standalone homes.

### Per-package levers, on both sides

Which packages o3 and lto may touch is no longer a list inside
`tuning/overlays/o3.nix` / `gentoo-lto.nix`: it becomes options, on the system
AND in homes.

```nix
# host file -- the system's set; defaults are today's lists
my.tuning.o3.candidates  = [ ... ];      my.tuning.lto.candidates = [ ... ];
my.tuning.o3.exclude     = [ ];          my.tuning.lto.exclude    = [ ];

# a user's home -- that user's set only
my.tuning.packages.lto = [ "foldpen" ];  my.tuning.packages.o3 = [ ];
my.tuning.exclude.lto  = [ ];            my.tuning.exclude.o3  = [ ];
```

- System candidates are still gated by the classifier (tuned only where
  host-runtime), as today; `exclude` is for a package a lever breaks.
- A user's `packages` are added inside THEIR set only (their variant is its
  own fixpoint), so tuning a library there rebuilds its dependents for them,
  not for anyone else. An explicitly listed name BYPASSES the classifier --
  the user asked for it -- and under march is also exempt from upstream
  substitution. Evidence (below) stays shared; per-package choices do not.
- Like `my.tuning` itself, these must be literals that do not read `pkgs`.
- Without a lever a user can still write their own derivation, override a
  package, or take one from `inputs.nixpkgs-upstream` -- the levers add the
  system's exact treatment (flags, per-package exceptions, rebuilt
  dependents), not a capability nobody had.

### Surface compatibility

Computed, not hand-curated, and enforced at evaluation: a home whose package
set cannot safely load the system's in-process code FAILS to evaluate.

1. The surface is what `lib/epoch.nix` already computes: system derivations
   reachable through the session environment (plugin paths: Qt, GTK, GIO, IM
   modules), the graphics driver, PAM, NSS and the locale, adjusted by
   `my.epoch.extraSurface` / `ignoreSurface`.
2. For every library in the closure of every surface derivation, the same
   package in the user's set is looked up and its ABI identity compared:
   pname, version, source, and patch list. Build flags (march, -O3, LTO,
   anything in NIX_CFLAGS_*) are NOT part of it. With one pin only the fork's
   own patches can differ (qtPatches on qtbase, ...), so this flags exactly
   those and nothing else.
3. Any mismatch fails `mkHome` with an ELABORATE message, not a one-liner:
   which surface item (e.g. the fcitx5 Qt IM module in the system profile),
   which library differs between the system's and the user's set and how
   (which patches), why that matters (the system's build is loaded into the
   user's processes, which already have their own copy of that library; the
   loader reuses theirs, the plugin was compiled against the other one's ABI
   -> crashes or silent corruption, typically at first use of that plugin),
   and what the user can do: set the lever that causes it back to "system"
   (named), or choose the march the host has (the fork carries the patch), or
   exclude that package from their per-package lists.
4. The locker is not special-cased: if it comes from the user's set, the PAM
   modules it loads are surface like any other and go through the same check.
   Singleton SERVICES (daemon, dbus, polkit, logind, greetd, portals,
   compositor and its plugins) always run from the system's set and are not
   checked -- users reach them over protocols.

#### Open question: perl and sqlite on the march hosts (evidence, 2026-10-24)

The agreed rule stands (any mismatch fails). This is the evidence for
deciding whether these two should be exempted, gathered without builds:
galaxybook4-pro360's own outputs (realised CA paths in its store) against
nixpkgs-upstream's (in the store, also on cache.nixos.org). Not compared on
victus-15 (its outputs are not in this store); its set takes the same
cross branches.

Why they differ at all: in the IntraISACross set `buildPlatform.canExecute
hostPlatform` is false and `buildPlatform != hostPlatform`, so nixpkgs takes
its cross branches.

**sqlite 3.53.3** -- 3 patches only in the system's build, all under
`lib.optionals (buildPlatform != hostPlatform)`, all fetched with `includes`
limited to build files: sqlite commit 67c202ab (`main.mk`: adds
`-DBUILD_sqlite` to `T.compile.tcl`, the TCL-extension compile, for
Unix-on-Windows cross), d501b949 and e4e1b4a4 (`autosetup/sqlite-config.tcl`:
untangle `--with-tcl`/`--with-tclsh`). nixpkgs marks them "not cross-specific,
make unconditional next mass rebuild". Compared outputs:
- file lists of `out` and `dev`: identical;
- `sqlite3.h`, `sqlite3ext.h`: byte-identical; `sqlite3.pc`: identical modulo
  store paths;
- `libsqlite3.so.3.53.3`: the same 368 exported dynamic symbols, the same
  NEEDED (libm, libz, libc), the same 57 embedded compile-option strings
  (`ENABLE_FTS5`, `THREADSAFE`, ... down to `COMPILER=gcc-16.2.0`).
By every installed artifact the two are the same ABI; only code generation
(march/O3/LTO) differs, which the rule already accepts. Where it is really
in-process: `pam_lastlog2.so` (util-linux) links libsqlite3, but on the
running system it is only in `login`'s stack, not in a screen locker's; the graphics closure
reaches sqlite only through python3.

**perl 5.42.3** -- the patches (`cross.patch`, `cross-fdopendir.patch`,
`perl-cross-1.6.4--5.42.3.patch`) are the visible part of a different
BUILD: the cross branch configures with perl-cross instead of `Configure`.
The outputs differ for real:
- archname `x86_64-linux` (system) vs `x86_64-linux-thread-multi`
  (upstream): every XS module lives under a different directory;
- `useshrplib=false`: the system has only a static `CORE/libperl.a`, its
  `bin/perl` NEEDs no libperl; upstream ships `libperl.so` and links it;
- 332 `Config_heavy.pl` keys differ, among them `use64bitint`/`use64bitall`
  (undef vs define; `ivsize`=`uvsize`=8 on both, so IV width is the same),
  `sig_count` (0 vs 65; `sig_name`/`sig_num` are the same), `ccflags` (no
  `-D_REENTRANT`, no `-fstack-protector-strong` recorded) and `optimize`;
  the same: threads/multiplicity, all sizes, byte order, `api_versionstring`.
So perl is NOT ABI-neutral between the sets. But there is no in-process path
on the surface: the system has no `libperl.so` anything could load; the
graphics driver's runtime closure (/run/opengl-driver) contains no perl at
all -- mesa is reached only because the walk follows `buildInputs`; and the
system profile's perl is a program, whose XS modules a user's perl would not
find (different archname directory) and would refuse at load if it did
(perl's XS handshake croaks on a mismatched interpreter instead of running).

Not part of the question but seen in the same run: a home without r0k0r's
own modules on galaxybook4-pro360 is also refused for `libsigc++` (system
3.8.1 through easyeffects, the home's 2.12.1). That is the check keying by
pname: the two are different libraries (`libsigc-3.0.so.0` vs
`libsigc-2.0.so.0`) and can share a process. A precision issue of the walk,
not a fork patch.

Options for the decision: (a) keep failing; (b) an explicit, reviewed
exemption list in `lib/surface-check.nix` (sqlite on this evidence; perl on
the "no in-process path" argument, which is about the surface as walked, not
about the two builds); (c) make the walk follow runtime references (needs
outputs, i.e. builds -- the reason it walks `buildInputs` today).

### Every user feeds the classifier

The classifier (`tuning/runtime-cache/lookup.nix`) decides what the levers
touch: o3/lto candidates that are host-runtime get tuned; under march,
host packages that are NOT host-runtime are substituted from upstream. Today
its caches see a standalone home only through the system's own evaluation of
it (system feature modules, `home.packages`), and live in the flake. They
move out and split per user:

```
/var/lib/tuning-cache/<host>/system-tier1.nix    tier 1 of the system
/var/lib/tuning-cache/<host>/system-tier2.nix    tier 2 of the system
/var/lib/tuning-cache/<host>/users/<user>.nix    that user's evidence
```

Plain directories, per host, not a flake and not a git repo. Users write their
own file; root may write anyone's. Each file is stamped with the nixpkgs hash
it was taken against (stale = ignored, as today). The host's final cache is
the UNION of all files in its directory -- every user's evidence counts,
automatically.

A user's evidence is BOTH:
- the closure of their current home generation (tier 1's method: everything
  the home references, after a switch), and
- an evaluation of their home repo (tier 2's method: their own modules
  included, before a switch).

`tuning-refresh` produces it. Users run it for themselves; root runs it for
users who did not -- ALWAYS AS THE USER (runuser / systemd-run --uid; an
overlay guest through their user service, which has their namespace), never
as root: a user's flake.lock can name root-only paths, and a root evaluation
would copy them into the world-readable store. Root's own runs cover the
system file and, after a nixpkgs bump, every user (every stamp goes stale at
once).

The system flake reads each host's directory as a locked input:

```nix
tuning-cache-galaxybook4-pro360 = { url = "path:/var/lib/tuning-cache/galaxybook4-pro360"; flake = false; };
tuning-cache-victus-15          = { url = "path:/var/lib/tuning-cache/victus-15";          flake = false; };
```

Relocking is by hand, one admin script (`scripts/tuning-cache-relock.sh`):
1. check: this host's `users/*.nix` are each owned by the user they are named
   after (or root) and world-readable, else refuse;
2. gather: copy every other host's directory to the relocking machine, same
   path, keeping only user files their owner wrote;
3. relock: `nix flake update tuning-cache-<migrated hosts>`, commit;
4. GC roots for the locked store paths, here and on every host distributed to;
5. distribute: `nix flake archive --to` every reachable host -- so a host
   whose directory changed since (users keep writing) still evaluates the
   locked content.

Accepted consequences:
- Any user's evidence changes the shared set: what it marks host-runtime is
  tuned for everyone following the system and, under march, no longer
  substituted from upstream -- rebuilds on the shared builders, and the
  epoch moves when the surface is touched (homes rebuilt, re-login).
- A package is classified only after a refresh and relock, so a new one is
  built twice: from the old cache first (untuned/upstream under march), tuned
  after.
- User files are Nix, evaluated by every system rebuild; a broken one breaks
  the rebuild and the admin fixes it.
- Relock commits are manual.
- Tombstoned users' files are removed (or skipped by the merge).

### Running the migration

Reviewed 2026-10-24 against what the hosts are now. What changed in the
scripts, and why:

- **Where the system's files are written** (`tuning/runtime-cache/cache-dir.sh`)
  is decided by `flake.lock` (does `tuning-cache-<host>` point at
  /var/lib/tuning-cache?), no longer by whether that directory exists.
  `userCache.enable` creates the directory at its switch, BEFORE the inputs
  move: by existence, a `cache-refresh` in that window wrote where no
  evaluation reads and the in-repo copy the rebuild used silently aged.
  Once migrated, a host's files are written ON that host only: the relocking
  machine's copy of another host is a mirror the next gather replaces, so
  refreshing another migrated host is skipped with a message (Tier 2 and
  Tier 1-over-ssh alike); in-repo hosts work as before.
- **Impermanence.** /var/lib/tuning-cache is declared in
  `my.state.system.state` (a bind mount from /persist on galaxybook4-pro360,
  checked by `tests/user-tuning.nix` `userCacheOn`). The migration refuses to
  seed an impermanent host whose /var/lib/tuning-cache is not a mount yet:
  the files would land on the tmpfs root and vanish at the next boot.
- **Untrusted users and the shared users/ directory.** It is sticky and
  world-writable, so anyone can create any NAME in it (a sticky directory
  only stops deleting others' files). The relock refuses a local
  `users/<u>.nix` not owned by `<u>` (or root), and gathers only correctly
  owned files from other hosts; `lookup.nix` additionally ignores a file
  whose `user`/`host` fields do not match its name and directory (not a
  security boundary, a guard against copies). `tuning-refresh` writes 0644
  whatever the umask (the gather reads as the admin, not root). Root's
  `--user`/`--all` run the user's refresh with a clean environment
  (`runuser ... env -i`), and a user without a home repo is skipped (exit 2),
  not a failure. Nothing a user writes needs the daemon's trust: it is
  evaluation plus `nix-store -q`.
- **The locked paths need GC roots.** The caches are read at evaluation and
  referenced by no output, so the first GC after a relock deletes them, and
  the next evaluation fails with a NAR hash mismatch as soon as the directory
  has changed. Measured with Nix 2.35.2 (scratch flake): a locked `path:`
  input whose store path is valid is used as is, with the directory changed
  or even gone -- so a rooted (or distributed) copy is all a host needs. The
  relock roots them in /nix/var/nix/gcroots/tuning-cache/ here and as the
  admin's indirect roots (~/.local/state/tuning-cache/gcroots) on every host
  it distributes to. The evalWorker path (`nixos-rebuild` evaluating on
  victus-15) is unaffected: it `nix flake archive`s the checkout, inputs
  included, at every rebuild.
- **Idempotent, with a dry run.** `scripts/tuning-cache-migrate.sh [-n]`
  (seed this host) and `--switch-inputs [HOST...]` (the relocking machine);
  `scripts/tuning-cache-relock.sh [-n]` (the dry run writes the would-be lock
  to a temp file and diffs it). Seeding never overwrites, the URL rewrite
  only matches the in-repo form, a host ssh cannot reach keeps its input in
  the repo (dell-latitude: no route from galaxybook4-pro360 today), and
  `--switch-inputs` refuses a reachable host that is not seeded yet.
  `TUNING_CACHE_ROOT` points both at a scratch directory for trying them.
- /etc/nixos: the scripts and `tuning-refresh` take the flake from their own
  checkout / `my.tuning.flakePath` (default /etc/nixos), which is now a real
  directory on both galaxybook4-pro360 (persisted from /persist/etc/nixos)
  and victus-15 (checked 2026-10-24: a directory at 4c41011, not the old
  symlink).

**Order.** One flake.lock holds every host's input, so the order is about
who must be seeded before the relocking machine locks what it gathered:

1. Commit `my.tuning.userCache.enable = true` for victus-15 and
   galaxybook4-pro360 (dell-latitude can wait: unreachable, untuned, no
   system files; its input stays in the repo). Evaluated: it changes each
   toplevel only by `tuning-refresh` (+ its fish completions on victus-15),
   the tmpfiles rules and, on galaxybook4-pro360, the /var/lib/tuning-cache
   bind mount and its persistence directory -- no package of the tuned set
   moves (`nix build --dry-run`: exactly `tuning-refresh.drv` and
   `unit-var-lib-tuning-x2dcache.mount.drv` added on galaxybook4-pro360).
2. **victus-15 first**: switch it, then on it `scripts/tuning-cache-migrate.sh -n`
   and without `-n`. First because the relocking machine gathers victus-15's
   directory and would otherwise lock an empty cache for it (all its tuning
   back to Tier 3); `--switch-inputs` refuses that case anyway.
3. galaxybook4-pro360: switch, check `findmnt /var/lib/tuning-cache`, then
   `scripts/tuning-cache-migrate.sh -n`, `scripts/tuning-cache-migrate.sh`,
   `scripts/tuning-cache-migrate.sh -n --switch-inputs` and finally
   `scripts/tuning-cache-migrate.sh --switch-inputs` (rewrites flake.nix,
   gathers, relocks, roots, distributes).
4. Evaluate both toplevels: they must equal step 1's. Measured in advance:
   galaxybook4-pro360 with userCache on and its input overridden to a copy of
   the migrated directory (the two tier files, an empty users/) evaluates to
   the same drvPath as with the in-repo input. Then commit
   `flake.nix flake.lock` and pull that commit into victus-15's /etc/nixos.
5. The first real `tuning-refresh` (each user, on their host) and a relock.
   This one is MEANT to change the set: measured with r0k0r's evidence on
   galaxybook4-pro360 today (`tuning-refresh --print`: 1328 names, 1141 from
   the home generation's closure, 563 from evaluating ~/config/home), only 3
   names are new to the system's tiers (intel-sde, shader-slang,
   tree-sitter-odoc), and the toplevel gains exactly one build:
   `shader-slang-x86_64-unknown-linux-gnu-2026.19` (kitty's, host-runtime
   now, so built tuned instead of substituted from upstream), plus 4 fetched
   sources. (The dry run lists ~1095 derivations for the baseline
   too -- under CA it over-reports, and today's main may not be built here
   yet -- so only the differences between variants are meaningful.)

## Threat model

In scope: a user (member or guest) must not be able to change the system, other
users' homes, or the admin's store contents; a guest must not be able to feed
anything into a build the admin will later use; a user's broken home must not
lock them out (fallback session) and a system change must not silently run a
home against singletons it was not built for (epoch).

Explicitly **out of scope** -- each user's own responsibility, no system fixes
wanted:

- shared `/tmp`
- localhost ports (one user's services reachable by another on 127.0.0.1)
- uinput across seat switches (a uinput grant is seat-wide input injection)
- physical access to the machine
- TPM2 unlock without a PIN: accepted, it follows from accepting physical
  access

## Implementation plan

### Done on the `multiuser` branch

Items 1-5 leave both hosts' toplevels byte-identical; item 6 is the first
deliberate system change.

1. **Registry data + validation.** `registry/users/`, `registry/types.nix`,
   `registry/hosts.nix`, `lib/registry.nix` (preset merge, override policy,
   contradictions, narrowing, uid/tombstone checks); both hosts' `my.users`
   come from it. Axes without machinery are refused as "not implemented yet".
2. **homeLib + standalone home.** `lib/home-generator.nix` as the one home
   generator; `homeLib.<host>` (pkgs, osConfig shim, modules, facts, mkHome);
   `templates/home`; r0k0r's home repo, whose activation packages equal the
   integrated ones on both hosts.
3. **Nested features.** Recursive feature walk, features grouped into
   categories, leaf-name import order.
4. **Fork only for march.** `enable = true, march = null` gets upstream nixpkgs.
   **lto and o3 without march** run in a native mode on upstream nixpkgs
   (`tuning/overlays/native-target.nix`, `tuning/native-build-tools.nix`, the
   native branch of `upstream-tools.nix`); the matrix evaluates `lto`, `o3`
   and `lto-o3` without march.
5. **handover and untrusted types** (step 9 of the original plan): tmpfs
   homes bound to `user@<uid>.service` with logind killing those users'
   processes at logout, kiosk sessions (cage + a system package), `nix =
   none` via allowed-users (written only on a host that has such a user),
   `nix = untrusted` asserted out of trusted-users, honest nix facts in
   homeLib (`facts.nix`), `narrow.<user>.localBuilds` accepted only where a
   host policy already makes it true. The deployed-type record and
   `acceptTypeChange` exist behind `my.registry.recordTypes.enable`, off.
   Evaluated by `tests/user-types-eval.sh`. Still open: logind's 10 s
   UserStopDelaySec window. (Kiosk pinning and handover credentials: 13
   below. Impermanent homes and overlay stores: 10 and 11.)
6. **trusted-users and uids from the registry.** `trusted-users` is
   derived in `nix-access.nix`: the host's `nix = admin` accounts plus
   `my.registry.nix.extraTrustedUsers` (non-people); `my.nix-settings.
   trustedUsers` and the host files' lists are gone. Every account's uid is
   pinned from its registry file (live uids checked first: r0k0r 1000,
   benjamin 1001). Effect on the hosts: `nix.conf` unchanged
   (`trusted-users = root r0k0r` as before); `users-groups.json` gains the
   uids, and home-manager's activation gains its `checkStringEq UID` line
   -- 18 changed derivations on galaxybook, 24 on victus, all activation
   and etc glue, no packages.

7. **People untrusted.** The admin preset is `nix = untrusted` (overridable),
   so trusted-users is root on galaxybook and root + nix-ssh on victus.
   victus serves builds as `nix-ssh` (`my.remote-builder.server` =
   `nix.sshServe`, ssh-ng, write, trusted, forced to its own nix-daemon,
   builder key only); a peer's `daemonUser` names it for /etc/nix/machines
   and the ssh-ng substituter, `sshUser` stays the person's login for the
   wrappers' untrusted steps. Wrappers that pin builders re-exec under sudo
   (or sudo just the copy-back and build).
8. **Builder key root-only, grants -> groups, type record on.** The builder
   key is the trust credential on a peer, so its agenix secret is root
   0400 and the peers' ssh_config blocks give it (and the /run control
   socket) to `localuser root` only. People use their own keys: registry
   `sshKeys` -> openssh.authorizedKeys, `my.ssh.identityFile` =
   `~/.ssh/id_ed25519` (r0k0r's was generated 2026-10-17 and appended by hand
   to victus-15 and yulee; note10 was offline). extraGroups are derived from
   grants (`grantGroups`); `groups` keys are refused -- which also fixes
   accounts without a list getting my.users' default, wheel included.
   `my.registry.recordTypes` is on for both hosts.

9. **Home-manager cutover, per account.** Registry `homeActivation`
   ("system" default | "standalone"); r0k0r is standalone, benjamin stays
   integrated (no repo). Standalone accounts are not in home-manager.users;
   the system ships the home-manager CLI (system Nix inside its
   nixos-option) and tier2-eval evaluates their homes through the same
   generator, so the anchor set is unchanged (+ the CLI itself). mkHome's
   asSubmodule defaults per account. r0k0r's home.path is the same
   derivation as the integrated one on victus-15; on galaxybook it differs
   only by two session vars naming ~/.nix-profile. Toplevels: home packages
   leave the system closure; glue, the CLI and inetutils (its dependency)
   change; no package changes. Deployment order: victus-15, then per host
   activate the home first, then switch the system (home repo README).

10. **guest-overlay** (`features/nix/guest-overlay`, `features/core/btrfs-layout`).
    Per guest (registry nix = "overlay"): lower = read-only btrfs snapshot of
    /nix taken at boot and after each activation, made consistent first (WAL
    checkpointed into the copy, unregistered store entries removed), published
    as /nix/.guest-lower/current, pruned when no mounted guest uses it; upper,
    work and state on the guest's own subvolume /var/lib/nix-guests/<user>
    (optional qgroup quota); nix-guest-overlay-<user>.service mounts
    /var/lib/nix-guests/.merged/<user> before logins and rebases (drop upper
    copies the lower now has, reflink copy-up of what the lower lost) only when
    no process of the guest is alive -- on boot and on user@<uid> stop.
    pam_namespace (no init script: it would run as root after the bind, from the
    guest's view) binds the merged store over /nix/store and a real-file
    /etc/nix over /etc/nix in login, su, systemd-user, sshd, greetd, sudo
    sessions; the guest's nix.conf opens local-overlay:// directly. The merged
    root is root:<group> 1775 so lower objects cannot be renamed or replaced;
    lever `wrappers` (hidden default | shared) decides /run/wrappers in guest
    namespaces. Shared daemon: guests excluded from allowed-users. Registry:
    the host fact features.<host>."guest-overlay" must equal the switch;
    overlay + home-manager needs homeActivation = standalone; overlay users may
    have builders. victus-15 now declares its existing /nix subvolume through
    btrfs-layout (toplevel unchanged). Eval-tested (tests/guest-overlay.nix),
    never run.

11. **dell-latitude, benjamin's machine** (ported from github:sihooleebd/nixos
    with his commits credited). benjamin becomes an `admin` with a standalone
    home (victus-15 narrows his grants back to sudo + network, so his groups
    there are unchanged; his integrated home-manager configuration leaves the
    victus-15 toplevel). `hosts.<host>.localPasswords`: dell keeps his password
    local, because `age/hashed-password-benjamin.age` is encrypted to victus-15
    only. `hosts/dell-latitude` is untuned (plain upstream nixpkgs, everything
    substitutes) and a remote-builder client of yulee and victus-15 over a
    different tailnet (`peers.<n>.address`, `my.remote-builder.server.extraKeys`
    for his own builder key, still to be provided). New features: tuigreet,
    tailscale (watchdog, resolved, stable Wi-Fi MAC), syncthing, opendisplay,
    kakaotalk-system, and an optional plymouth splash in `boot`. Shared
    features gained `my.keyd.layout`/`perDevice`, `my.emacs.font`,
    `my.power.profile` (default "powersave" = what the module hard-wired; the
    static EPP udev rule is gone and power-profiles-daemon is pinned instead,
    which changes galaxybook's toplevel), and the kitty kitten URLs are pinned.
    His desktop (bonfire, pyre, lyre, ...) is his home repo's. Eval-only.

11. **Impermanence** (features/core/impermanence; design HANDOFF §5.6 + per-user
    lists, 2026-10-18), off everywhere, eval-only. btrfs rollback of @root in
    the systemd initrd (old roots kept 14 days); system persistence through
    nix-community/impermanence from defaults + features' my.state.system;
    per user, each user suggests their list (home option my.persist, written
    to /persist/home/<user>/.persist.json at activation) and the system
    merges it at boot with features' my.state.user and the home-manager state
    (persist-home-<user>, then hm-reactivate-<user>). Registry home =
    "impermanent" is live. 36 features declare their state. galaxybook is
    prepared, not migrated: hosts/galaxybook4-pro360/impermanence.nix +
    flake output migration.galaxybook4-pro360 + docs/impermanence-migration.md
    (the live-USB runbook). Open: /var/lib/nix-guests as a bind mount,
    .config/noteworthy to agenix (HANDOFF 5.5).
    Migrated and committed on galaxybook4-pro360 on 2026-10-24 (live there).

12. **Optional features split out** (Next 8) **and luks.** Each optional piece
    is its own feature in `_meta`'s graph, declared while off: btrfs-layout,
    impermanence (requires btrfs-layout), guest-overlay (requires
    btrfs-layout), ccache and ccache.builder, ca-derivations, luks (requires
    nothing). Most of the split had already happened piecemeal: ccache and
    ca-derivations were features with their own options, and tuning only
    consumes them (tuning/heavy.nix reads my.ccache.wrapperConfig and warns
    on an unconsumed client half; tuning/ca.nix applies the "tuned" policy
    because it needs tuning's classifier and heavy.skip; moving it into the
    feature would also move its overlay in nixpkgs.overlays, which is
    ordered by import order, so it stays). What was missing was ccache in the graph and
    luks. Requirements that are not features stay ordinary assertions:
    march for packages = "tuned", the systemd initrd for impermanence and
    luks, agenix for a ccache builder on the default key. `luks`
    (features/core/luks): LUKS2 + TPM2, no PIN, crypttab
    `tpm2-device=auto` + `discard`, PCR 7 by default (why, and what changes
    it, in the header), `luks-tpm2-enroll` for (re-)enrollment, recovery
    key and header backup documented, assertions for a filesystem or the
    rollback pointed at the LUKS header. No ordering code: the rollback
    already waits on the btrfs's own device unit, which appears only after
    the unlock. galaxybook4-pro360 is prepared, not encrypted:
    hosts/galaxybook4-pro360/luks.nix (LUKS UUID chosen in advance for
    `cryptsetup reencrypt --uuid`), migration.galaxybook4-pro360-luks,
    docs/luks-migration.md. Toplevels of all three hosts unchanged;
    `tests/optional-features-eval.sh`.
13. **Kiosk pinning and handover credentials** (Next 9). Pinning is
    enforced below the greeter (features/core/users/kiosk.nix): greetd always
    runs a session as `/bin/sh -c '. /etc/profile; ...; exec <cmd>'`, so the
    first lines of /etc/profile (mkBefore, ahead of its sourced-once guard)
    exec the account's launcher when `id -u` is a kiosk uid -- the command
    the greeter sent, remembered or had typed in is never reached. The
    launcher (`kiosk-shell-<prog>`: refuses any argument, sources
    /etc/set-environment, `cage -s -- <prog>`) is also the account's login
    shell, so a VT login lands in the same session; it is named through
    /run/current-system/sw and is not in /etc/shells (su -s is ignored for
    non-root). ssh is refused (sshd DenyUsers + a pam_succeed_if account
    rule) and so is su (pam_succeed_if, root included); `-c` is refused by
    the launcher. Registry: a kiosk account may not set `shell` or
    `sshKeys`. Credentials (features/core/users/handover.nix): no fixed
    password and no autologin -- `sudo handover issue <user> [--for ... |
    --until ...]` ends the account's sessions, generates an 80-bit
    passphrase printed once, stores only its yescrypt hash
    (hashedPasswordFile under persistRoot on an impermanent host, 0700 root
    dir) and applies it with usermod; the deadline (default 24 h) is an epoch
    file checked by a pam_exec account rule on `login` (greetd's account
    phase includes login's) that fails closed, plus a transient realtime
    timer that revokes at the deadline. `handover revoke`, `handover
    status`. User-file `handover.expires = "YYYY-MM-DD"` is the hard ceiling
    (users.users.expires, checked by pam_unix for every service; issue
    refuses past it); `passwordSecret` on a handover account is refused.
    No host has a kiosk or handover account: toplevels unchanged.
    `tests/user-types-eval.sh` checks the pin, shell, PAM stacks, ssh,
    credential file, seed ordering and the refusals. Not run on a machine
    yet (runtime plan in the commit/report); no VM test.

14. **Epoch + history + fallback session, on for galaxybook4-pro360**
    (Next 7, 2026-10-24). my.epoch: `epoch.json` {epoch, rev, host} in the
    toplevel, /etc/nixos-epoch, `nixos-epoch-record.service` (boot and
    switch; RequiresMountsFor the persisted /var/lib/nixos-epochs, declared
    through my.state.system.state) appending to history.jsonl and
    backfilling the boot menu, hm-switch (advisory check) and hm-rollback.
    Every home built for a host with the epoch on records it: the epoch
    module (`$generation/epoch`, `$generation/system-rev`) is in
    home-manager.sharedModules, which homeLib's mkHome evaluates too, so no
    user repo has to opt in (homeLib.<host>.epochModule stays exported,
    deduplicated by its module key); homeLib facts gain `epoch` (and
    `impermanence` now reports the registry fact instead of a constant
    false). my.fallback-session.guard (replaces `guardSessions`): the
    sessionData `desktops` aggregate is rebuilt from the same
    sessionPackages with every Exec= prefixed by guarded-session under the
    same file names (so the greeter's remembered "hyprland.desktop" is the
    guarded one), plus `<id>-ignore-epoch` entries; mkAfter puts the
    definition last in sessionData's untyped `//` merge (definitions arrive
    in reverse module order: without it upstream's won) and an assertion
    checks the result. guarded-session: match -> the session; mismatch or
    no generation -> fallback-session; unrecorded -> the session unless
    unrecordedIsMismatch; only accounts with a home-manager home are
    checked (kiosk and the fallback entry itself are passed through,
    `passthru.epochGuard = false`); EPOCH_GUARD=passed lets a nested guard
    (uwsm resolving hyprland.desktop) through. tuigreet keeps its own
    entries and applies the same routing when the guard is on. The epoch is
    unchanged by all of it (`desktops` is in ignoreSurface by name).
    galaxybook4-pro360: epoch, fallback session and guard on,
    unrecordedIsMismatch off until the home has been switched once on the new
    revision. victus-15 and dell-latitude unchanged. Eval-tested
    (tests/session-safety-eval.sh); not run yet -- runtime plan in the
    README.

12. **Class daemons + hm-switch builder variations** (2026-10-24).
    features/nix/class-daemons: per class present on a host, socket-activated
    nix-daemons at /nix/var/nix/daemon-socket-<class>/<variant> (default,
    one per builder, local), root:nix-class-<class> 0660; NIX_CONF_DIR files
    that `include /etc/nix/nix.conf` and override allowed-users, trusted-users,
    builders, max-jobs, substituters (+ restated require-sigs/sandbox); a
    per-class builder key (agenix or a root 0400 file) used through a class
    ssh_config; NIX_REMOTE routing. Registry fact
    features.<host>."class-daemons" (false everywhere), _meta requires
    (remote-builder.client when a class has builders, agenix for its key).
    hm-switch: its own switch `my.epoch.hmSwitch.enable` (default
    my.epoch.enable), epoch check advisory and skipped when the epoch is off,
    `--on PEER` / `--local` / `--eval-on PEER`, built through the class
    daemon's socket, else `sudo` for the build of the finished .drv only
    (sudo-grant users), else the system's builders with a note; activation
    always the user's. On for galaxybook4-pro360 (only a package on PATH).
    Eval-tested (tests/class-daemons-eval.sh); class daemons never run -- the
    runtime plan is in the README.

14. **Per-user graphics driver** (2026-10-24). features/session/gl-namespace:
    `/run/opengl-driver -> /run/gl-driver/view/tree`, the view a real
    directory polyinstantiated by pam_namespace (user method, noinit, the
    mapped users only) over `/run/gl-driver/inst/<user>`, whose `tree` link
    names the user's tree or `/run/gl-driver/system` (the system's buildEnv,
    same derivation as before, so the epoch is unchanged). A directory and a
    link, not a bind over the old symlink: pam_namespace would follow it and
    bind over the system tree's store path, which the next switch leaves
    behind. The home declares the tree (`my.graphics.driver`: a buildEnv from
    the home's own set, the system's graphics packages by pname by default,
    linked as `$generation/graphics-driver`); `gl-driver-select` (root, pam_exec
    before pam_namespace, and a path unit on the home-manager profile)
    resolves the current generation's link, accepts only a root-owned
    top-level store directory, repoints the instance and keeps a gcroot.
    Session stacks: login (greetd includes it), su, sudo, sshd, systemd-user
    -- user@.service gets its own namespace binding the same instance, so the
    user manager (the desktop under uwsm) sees the same tree. Surface check:
    a home with its own driver skips "graphics" and checks its tree against
    the system profile (group "driver"); the fallback session's cage runs
    through `gl-system-driver`. Trust: the setuid/setcap assertion and
    build-time check above. Off everywhere, toplevels unchanged;
    `tests/gl-namespace-eval.sh`, `tests/gl-namespace-select.sh`; the
    build-time check was run once on victus-15 (passes) and galaxybook4-pro360
    (fails on Hyprland, as expected). Never run on a machine; runtime plan in
    the README.

### Next

6. **hm-switch**: on for galaxybook4-pro360, with the epoch check since
   Done 14. Next: class daemons' first run (README runtime plan), then
   hm-switch through them.
7. ~~**Epoch + history + fallback session**~~: implemented and on for
   galaxybook4-pro360 (Done 14); left: the first switch + reboot (README
   runtime plan), then `unrecordedIsMismatch = true` there; victus-15 (the
   NVIDIA surface) after its /etc/nixos move; the PAM banner
   (`pamBanner.services`) is still off everywhere.
8. ~~**Optional features split out**~~: done (see 12 above); left: the
   LUKS migration of galaxybook4-pro360 itself (docs/luks-migration.md), and
   hibernation on an encrypted swapfile, if ever wanted.
9. ~~**handover and untrusted types**~~: done (see "Done" 5 and 13); left: a
   first real run (a handover account on galaxybook: issue, greeter login
   with another session selected, VT login, ssh/su refusal, deadline,
   revoke, reboot), and logind's UserStopDelaySec window.
10. ~~**guest-overlay**~~: implemented (see 10 above), not yet run. First run
    on victus-15 (btrfs-layout already true there): enable it plus a test
    guest, then check, in this order: the snapshot (`nix-guest-lower`), the
    mount, a guest login (`findmnt /nix/store` in the session), `nix store
    info`, a substitution, a build on a builder of the guest's own, GC in
    the guest store, a system switch during a session (the session keeps its
    lower; logout -> rebase), copy-up after an admin GC.
11. **nixosTest VM test** for the guest paths: written,
    `checks.x86_64-linux.guest-overlay-vm` (tests/guest-overlay-vm.nix),
    plain upstream nixpkgs. /nix is a real btrfs subvolume: a `mkfs.btrfs
    --rootdir --subvol nix` image of the VM's closure as the backing file of
    its root disk (mountHostNixStore and useDefaultFilesystems off). Its first
    runs found and fixed three bugs: nix-guest-lower died under pipefail on a
    store with nothing unregistered (grep -v with no output), and deleted the
    snapshot it had just published (its prune glob matched current/); the
    PAM rule broke evaluation on a host whose greetd stack is `include login`
    (dell-latitude, found by the matrix). It passes the subvolume, snapshot
    and overlay-mount checks; OPEN: in a `su guest` session /nix/store is not
    the overlay (findmnt prints nothing, pam_namespace logs nothing) -- next
    step is pam_namespace `debug` and a look at the session's mountinfo.
    Not coverable without network: substitution, the guest's own builders.
12. **Eval matrix**: done -- lib/matrix.nix `pieces` (march, lto, o3, heavy,
    ccache, ca, btrfs-layout, impermanence, guest-overlay; luks a TODO entry
    until it lands): all off, all on, each alone, combinations, and the
    invalid-by-design ones, which must fail with their assertion (checked by
    scripts/eval-matrix.sh). All 75 host/variant pairs as expected
    (2026-10-24). It found that impermanence on victus-15 needs /home
    neededForBoot and deduplicated persistence paths (fixed in the feature).
13. ~~**Per-user tuning**~~ implemented (see that section) and made ready
    to run (2026-10-24, [Running the migration](#running-the-migration):
    flake.lock-driven cache_dir, persistence check, owner check, GC roots,
    dry runs); left: the one-time cache migration (root; victus-15 first,
    then galaxybook4-pro360 with `--switch-inputs`), and a first real
    tuning-refresh + relock (measured in advance: r0k0r's evidence adds one
    tuned build, shader-slang). Measured on implementation: an untuned home
    on either march host is REFUSED by the surface check -- perl
    (cross.patch, cross-fdopendir.patch, perl-cross) and sqlite (cross-only
    autosetup tcl patches) differ between the IntraISACross set and a native
    one. The agreed rule (fail) stands; the evidence for deciding is in
    [Open question: perl and sqlite](#open-question-perl-and-sqlite-on-the-march-hosts-evidence-2026-10-24)
    (sqlite: ABI-identical outputs; perl: a genuinely different build with
    no in-process path on the surface).
14. **gl-namespace first run** (README runtime plan), after deciding
    Hyprland's cap_sys_nice wrapper (disable, or allowPrivilegedGL with a
    reason). Not handled: overlay guests (their tree lives in their own
    store), NVIDIA's userspace from a user's set (tied to the running kernel
    module; keep the system's driver there), 32-bit trees from a march set.
    Originally planned: the home option `my.tuning` and
    `mkHome`'s `_module.args.pkgs`; candidate lists as system options
    (`my.tuning.{o3,lto}.{candidates,exclude}`) and home options
    (`my.tuning.{packages,exclude}.{o3,lto}`); the surface compatibility check
    with its explanatory failure; `/var/lib/tuning-cache/<host>/` with
    per-user files, `tuning-refresh` (closure + evaluation, run as the user),
    lookup.nix reading the per-host locked inputs, the gather/relock/
    distribute script; the current tier1/tier2 files become the hosts'
    `system.nix`.
