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
own `pkgs` reuses the system's store paths.

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
- **ccache**
- **ca-derivations**
- **luks** -- TPM2 unlock, **no PIN** (the user's choice)
- **tuning** -- three independent levers, all default off:
  - `march` -- the only one needing the fork (and SDE Emacs where builders
    cannot run the target), decided pre-eval;
  - `lto`, `o3` -- independent of march. Without it they tune the native
    package set on upstream nixpkgs, skipping libraries a build tool links
    and keeping everything not host-runtime at its untuned derivation.
  Per-user `tuning.json` in the user repo, one add-only list per lever, applied
  user-side through the exported classifier on top of the base world.

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

### Next

6. **Cutover to standalone home-manager**: the system stops integrating
   home-manager for `session = home-manager` users; home repos switch to
   `asSubmodule = false`; `hm-switch` wrapper.
7. **Epoch + history + fallback session**, with Claude Code in the fallback.
8. **Optional features split out**: ccache, CA, btrfs-layout, luks,
   impermanence, each with `_meta` requires.
9. ~~**handover and untrusted types**~~: done (see "Done" above); left: kiosk
   session pinning, handover login credentials.
10. **guest-overlay**, only after testing the experimental pieces:
    `local-overlay-store` on frozen btrfs snapshots, `read-only-local-store`,
    and the build hook between overlays.
11. **nixosTest VM tests on victus** for the guest paths.
12. **Eval matrix**: all optional pieces off, all on, and each alone.
