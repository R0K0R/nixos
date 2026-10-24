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
  in a mount namespace rather than being a singleton.

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

## Trust and guest stores

**Sharing a store is sharing trust.** Anything a guest can write and the admin
later reads is an injection path. So:

- Guest sandboxes get **no writable shared state**: the admin ccache is
  read-only to them at most; `extra-sandbox-paths` is audited; `sandbox = true`
  everywhere.
- No setuid wrapper may have `/run/opengl-driver` in its RUNPATH (asserted).

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
`tests/user-tuning-eval.sh`. The caches are still in the repo: the migration
to /var/lib/tuning-cache needs root on each host.

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

### Every user feeds the classifier

The classifier (`tuning/runtime-cache/lookup.nix`) decides what the levers
touch: o3/lto candidates that are host-runtime get tuned; under march,
host packages that are NOT host-runtime are substituted from upstream. Today
its caches see a standalone home only through the system's own evaluation of
it (system feature modules, `home.packages`), and live in the flake. They
move out and split per user:

```
/var/lib/tuning-cache/<host>/system.nix          tier 1 + tier 2 of the system
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

Relocking is by hand, one admin script:
1. gather: copy every host's directory to the relocking machine, same path;
2. relock: `nix flake update tuning-cache-*`, commit;
3. distribute: `nix copy` every locked store path to every host -- so a host
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
   Evaluated by `tests/user-types-eval.sh`. Still open: pinning a kiosk user
   to the kiosk session (greeter), a passwordless/autologin handover login,
   logind's 10 s UserStopDelaySec window, impermanent homes and overlay
   stores.
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

### Next

6. **hm-switch** (features/core/epoch, off): turn on with my.epoch once the
   epoch history is wanted; plain `home-manager switch` works meanwhile.
7. **Epoch + history + fallback session**, with Claude Code in the fallback.
8. ~~**Optional features split out**~~: done (see 12 above); left: the
   LUKS migration of galaxybook4-pro360 itself (docs/luks-migration.md), and
   hibernation on an encrypted swapfile, if ever wanted.
9. ~~**handover and untrusted types**~~: done (see "Done" above); left: kiosk
   session pinning, handover login credentials.
10. ~~**guest-overlay**~~: implemented (see 10 above), not yet run. First run
    on victus-15 (btrfs-layout already true there): enable it plus a test
    guest, then check, in this order: the snapshot (`nix-guest-lower`), the
    mount, a guest login (`findmnt /nix/store` in the session), `nix store
    info`, a substitution, a build on a builder of the guest's own, GC in
    the guest store, a system switch during a session (the session keeps its
    lower; logout -> rebase), copy-up after an admin GC.
11. **nixosTest VM tests on victus** for the guest paths: needs a VM whose
    /nix is a btrfs subvolume (not the host-shared store the test driver
    mounts by default).
12. **Eval matrix**: all optional pieces off, all on, and each alone.
13. ~~**Per-user tuning**~~ implemented (see that section); left: the
    one-time cache migration (root, every host), and a first real
    tuning-refresh. Measured on implementation: an untuned home on either
    march host is REFUSED by the surface check -- perl (cross.patch,
    cross-fdopendir.patch, perl-cross) and sqlite (cross-only autosetup tcl
    patches) differ between the IntraISACross set and a native one. Both are
    build-system patches; whether that makes them ABI-neutral cannot be
    computed, so the agreed rule (fail) stands until decided otherwise.
    Originally planned: the home option `my.tuning` and
    `mkHome`'s `_module.args.pkgs`; candidate lists as system options
    (`my.tuning.{o3,lto}.{candidates,exclude}`) and home options
    (`my.tuning.{packages,exclude}.{o3,lto}`); the surface compatibility check
    with its explanatory failure; `/var/lib/tuning-cache/<host>/` with
    per-user files, `tuning-refresh` (closure + evaluation, run as the user),
    lookup.nix reading the per-host locked inputs, the gather/relock/
    distribute script; the current tier1/tier2 files become the hosts'
    `system.nix`.
