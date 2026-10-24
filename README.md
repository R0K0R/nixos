# NixOS system flake

The **system** half of a two-repo setup: hardware, boot, the nix daemon, the
singletons every session shares (kernel, glibc, systemd, greeter, locker), the
user registry and its types, the remote builders, and an optional tuning
backend. It is written by the admin and readable by every user. What lives
under a user's `$HOME` belongs in that user's own home-manager repo, which
builds on this flake's `homeLib` (see [Two repos](#two-repos)).

| host | role |
|---|---|
| `galaxybook4-pro360` | Samsung Galaxy Book4 Pro 360 laptop. Meteor Lake, Hyprland desktop. Dispatches builds to victus-15 and yulee. |
| `victus-15` | HP Victus 15. Ryzen znver3, headless, doubles as a remote builder. |
| `dell-latitude` | Dell Latitude (Comet Lake), Benjamin Lee's laptop. Untuned, so everything substitutes from cache.nixos.org; Hyprland session from tuigreet, his desktop in his own home repo. Dispatches builds to yulee and victus-15. |

The first two hosts currently turn on the `march` tuning lever, which puts them on an
IntraISACross build against a
[nixpkgs fork](https://github.com/R0K0R/nixpkgs/tree/combined-fundamental) --
see [Tuning](#tuning). A host with tuning off gets plain upstream nixpkgs and
substitutes everything from cache.nixos.org.

The agreed multi-user design this layout is heading towards, its threat model,
the alternatives that were rejected and the phase plan are in
[docs/multiuser-design.md](docs/multiuser-design.md). This README describes
what exists; anything not built yet is marked **planned**.

## Philosophy

**Registration is not activation.** Every module under `features/` is imported on
every host, always. `my.<feature>.enable` decides whether it does anything.
`imports` is never a switch.

Conflating the two is what the previous layout did, and every problem followed
from it: the aggregator was all-or-nothing, so the headless host could not import
it and hand-rolled its own drifting copies of locale/users/nix-settings; per-host
logic leaked into shared modules as `hostName == "victus-15"` tests; per-host
data leaked into shared files keyed by hostname.

**A feature is a directory, not a layer.** `features/session/dms/` owns DMS's
NixOS side, its home-manager side, its settings, its plugins and its upstream
inputs. Splitting by `nixos/` vs `home/` cuts every feature in half -- Emacs used
to span four files across two trees plus a host file.

**A host file describes a machine.** If reading it does not tell you what the
machine runs, the design failed. This is why dependencies are asserted rather
than auto-enabled: a feature that silently switches on three others makes the
host file a lie.

**A host file is clonable.** Copy it, change the hostname, get a working machine.
This is a test that runs, not an aspiration.

**A person is not a host setting.** Who a user is (uid, shell, type) is
flake-level data in `registry/`; a host only says which people live on it. Each
host used to carry its own copy of "who is r0k0r", and nothing compared them.

**Features are giftable.** `features/hardware/samsung-galaxybook/` references
exactly one external input and no other feature. Hand it to another Galaxy Book
owner and it works.

**Optional means optional.** Every expensive or invasive piece -- tuning,
ccache, content-addressed derivations, and later btrfs layout, impermanence,
guest stores, LUKS -- is off by default, and "all off" is a plain NixOS on
upstream nixpkgs. Turning one on must never silently require another; that is
what `_meta` requires are for.

**Fail loud, never quiet.** A missing value and an unreadable value must never
look alike. `or` defaults are how the first becomes the second.

**Comments record what was ruled out.** The obvious alternative is what
future-you will try again; say why it lost. Most long comments here are load-bearing.

## Two repos

| repo | who writes it | what it holds |
|---|---|---|
| this one, `github:R0K0R/nixos` | the admin; users read it | hosts, hardware, boot, the nix daemon and its builders, accounts and what they may do (`registry/`), tuning, the package set |
| a user's home repo, e.g. [`github:R0K0R/home`](https://github.com/R0K0R/home) (`~/config/home`) | that user | everything under `$HOME`: dotfiles, user services, user programs |

A home repo pins **no nixpkgs and no home-manager** of its own. It takes both
from this flake through `homeLib.<host>`:

| attribute | what it is |
|---|---|
| `pkgs` | the host's own package set (tuned, if the host is). A home built against it reuses the system's store paths; a second nixpkgs would be a second, untuned package set and rebuild everything. |
| `modules` | the feature `home.nix` halves plus Unstraightened's module -- the same `sharedModules` the integrated home-manager uses |
| `facts` | plain data: host, system, the tuning levers, the registry's effective axes per user |
| `osConfig` | the host's NixOS config. **Transitional**: the feature home halves still read `osConfig.my.*`; `facts` is meant to replace it. |
| `mkHome { username, modules ? [], asSubmodule ? <per homeActivation> }` | a home-manager configuration (`.activationPackage`) built by the same generator as the integrated `home-manager.users.<name>` |

`lib.homeConfigurationFor "<host>" { ... }` is the same as a one-call helper,
and `nix flake init -t github:R0K0R/nixos#home` creates a minimal home repo
(`templates/home/`).

`mkHome` deliberately does not use home-manager's `homeManagerConfiguration`:
that always re-imports nixpkgs with only `system` set, which on an
IntraISACross host is a different, untuned package set. It evaluates
home-manager's module list the way `nixos/common.nix` does instead
(`lib/home-generator.nix`).

### Who activates a home

Per account, from the registry file's `homeActivation`:

- **`"standalone"`** (r0k0r): the user's own repo activates the home with
  `home-manager switch --flake ~/config/home#<user>@<host>`. The system does
  not integrate it (no `home-manager.users.<n>`, no
  `home-manager-<n>.service`, no `/etc/profiles/per-user/<n>`), ships the
  `home-manager` CLI (the same home-manager input, the system's Nix), and
  still EVALUATES the home for the tuning classifier
  (`tier2-eval.nix` `standaloneHomes`), so its packages stay anchors.
  `mkHome` defaults to `asSubmodule = false`: packages go into the user's
  `~/.nix-profile`.
- **`"system"`** (default; benjamin, who has no repo): integrated as before,
  activated on every `nixos-rebuild switch`. `mkHome` defaults to
  `asSubmodule = true` and reproduces that home byte for byte.

Never both for one account: two activators for one home rewrite each other's
generation and profile links. Moving an account to standalone: create the
repo, activate its home once (`nix build ...activationPackage` then
`activate`: the CLI arrives with the system switch), then set
`homeActivation = "standalone"` and switch the system. The cutover kept r0k0r's
home packages the same derivations (`config.home.path`; on galaxybook two
session variables now name `~/.nix-profile`).

## Layout

```
flake.nix          inputs; picks the nixpkgs per host; mkHost; homeLib; registry
hosts/<name>/
  default.nix      what this machine is and what it runs
  hardware-configuration.nix   generated by nixos-generate-config
features/<category>/<name>/
  nixos.nix        declares options.my.<name>, body wrapped in mkIf
  home.nix         home-manager half, gates on osConfig.my.<name>
  packages.nix     { pkgs }: { system = [...]; user = [...]; home = [...]; }
  flake.nix        only if the feature owns external inputs (feat-<name>)
  README.md        for features meant to be handed to someone else
registry/
  users/<name>.nix one file per person, ever (uid, type, shell, password secret)
  types.nix        user-type presets over the axes
  hosts.nix        host -> users, primary, per-host groups; cross-host facts
  default.nix      loads the above through lib/registry.nix's checks
lib/
  feature-dirs.nix the recursive feature walk (also used by tuning's Tier 3)
  registry.nix     registry rules: preset merge, overrides, narrowing, uids
  registry-users.nix  registry -> my.users for the host being evaluated
  home-generator.nix  the one generator of a user's home (integrated + homeLib)
  home-manager.nix NixOS-integrated home-manager, on the generator
tuning/            march, overlays, CA, heavy (mold+ccache), runtime-cache classifier
templates/home/    `nix flake init -t .#home`: a user's home repo
age/ + secrets.nix agenix secrets (encrypted) and their recipient map
docs/              design notes and resolved investigations
scripts/           one-off and diagnostic helpers (see Rebuilding)
cross-debug*/      investigation logs from the IntraISACross bring-up
```

`secrets.nix` is read by the `agenix` CLI only, never by an evaluation; it holds
public keys and says how to add a host. The account passwords are system
secrets (`age/hashed-password-<user>.age`) because the system creates the
accounts.

## Features

### Discovery and categories

`flake.nix` finds features with a recursive walk (`lib/feature-dirs.nix`): a
directory holding `nixos.nix` or `home.nix` is a feature, and the walk stops
there; a directory holding neither is a category and is descended into. An
empty category and two features with the same leaf name are errors.

| category | features |
|---|---|
| `core/` | `_meta` (cross-feature requires/roles), agenix, base, boot (+ optional plymouth splash), locale, packages, swapfile, users |
| `nix/` | ccache, nix-settings, remote-builder |
| `hardware/` | cuda, embedded-keyboard, keyd, libinput, pipewire, power, samsung-galaxybook, touch-gestures, upower, x-folding-trackpad |
| `session/` | compositor, cursor-theme, dms, fcitx, fonts, greetd, hakuspace, hyprland, niri, qt-theming, session-env, session-services, sidedock, tuigreet |
| `net/` | discovery, globaltun, headscale, network, openvpn, syncthing, tailscale, wireless-display |
| `shell/` | eza, fish, ssh, starship, zsh |
| `apps/` | astro, claude-code, claude-desktop, claude-science, desktop-apps, easyeffects, emacs, firefox, flamenco, flatpak, fx570ex, hop, kakaotalk, kakaotalk-system, kitty, media, opencode, opendisplay, samsung-ecosystem, waydroid |
| `dev/` | arduino, dev-toolchain, diagnostics, direnv, latex, python-dev, qt-dev |

The category is organisation only. The option is `my.<name>` whatever the
category, leaf names are unique across the tree, and modules are imported in
**leaf-name order**, not depth-first. Import order decides list-option
concatenation and therefore the `paths` order of `system-path` and
`home-manager-path`; depth-first order would make what gets built depend on
which category a feature is filed under. Leaf-name order is exactly the old flat
`readDir` order, so moving a feature between categories changes nothing that
gets built.

Comments throughout the tree say `features/<name>` (e.g. `features/hyprland`)
meaning the feature, not a literal path. Many of those comments sit in files
copied into the store (`hyprland.lua` and friends), where rewriting them would
rebuild things.

Because discovery is a walk, there is no import list to maintain and no way to
leave a feature out by accident. The corollary is that a file's mere presence
activates it -- **nothing may live under `features/` that is not a real
module**. Four files were deleted during the original refactor for exactly this
reason; they had rotted unnoticed because the old hand-written list never
referenced them, and one did not even parse.

### Dependencies: `_meta`

A feature declares what it needs as data, and `features/core/_meta` turns that
into assertions:

```nix
my.internal.features.<name> = {
  enabledBy = cfg.enable;
  requires = [ "compositor" ];   # other features that must be enabled too
  provides = [ "shell" ];        # roles; at most one enabled feature per role
};
```

Two failures need telling apart. A missing feature *directory* fails at
evaluation anyway, with a useless "attribute missing" message. A feature that
is present but *not enabled* fails at nothing: it builds, switches, and leaves a
broken machine -- that is how the greeter crash loop in the hyprland feature
happened. So requirements are **asserted, never auto-enabled**, and the message
names the line to add. A feature without dependencies never touches the option,
which keeps it giftable.

### Feature sub-flakes

Features that own external inputs carry their own `flake.nix`, consumed by the
root as a `path:` input named `feat-<name>`. The root then keeps only what is
genuinely cross-cutting -- `nixpkgs`, `nixpkgs-upstream`, `home-manager` -- and
`rm -r features/session/dms` takes DMS, its greeter, its plugin registry and
their pins with it.

Two hazards live here, both hit during the extraction:

**`follows` must chain through two levels.** The sub-flake declares its own
`nixpkgs` so the wrapped input has something to follow, and the root points that
at the fork. Miss either half and you get a second package set -- its own glibc
and systemd -- not a cosmetic lock rename. Check with:

```sh
nix eval --json .#nixosConfigurations.galaxybook4-pro360._module.args.inputs \
  --apply 'i: builtins.mapAttrs (_: v: v.rev or null) i'
```

**Moving an input between flakes silently upgrades it.** There is no prior entry
to reuse, so `nix flake lock` resolves it fresh at HEAD. During the refactor that
bumped DMS from 2026-08-06 to 08-14 unnoticed. When relocating an input, pin it
to the rev from the old lock (`nix flake lock ./features/<category>/<n>
--override-input <x> github:owner/repo/<rev>`), then `nix flake update
feat-<n>` so the root re-reads it.

## Registry and user types

People are plain data at flake level, outside the module system, so every host
-- builders included -- and every home repo (through `homeLib.<host>.facts`) can
read them without evaluating another machine. `nix eval .#registry.effective`
shows what each user ends up with on each host.

**`registry/users/<name>.nix`** -- one file per person: `uid`, `type`, `shell`
(a package *attribute name*, resolved by the host's own pkgs), `passwordSecret`,
`sshKeys` (public keys that may log in as them; never the builder key, which is
root-only), optional `overrides` and `groups`; `tmpfsSize` (default `"2G"`) for a tmpfs
home; `acceptTypeChange = "<old>-><new>"` to consent to one dangerous type
change (below).

**`registry/types.nix`** -- presets over five axes:

| axis | values | meaning |
|---|---|---|
| `home` | `persistent` \| `tmpfs` \| `impermanent` | where the home directory lives |
| `nix` | `none` \| `overlay` \| `untrusted` \| `admin` | what the user may do with the nix daemon |
| `session` | `home-manager` \| `system-default` \| `{ kiosk = "<pkg>"; }` | what a login gets |
| `builders` | bool | may name builders/substituters of its own (needs `nix = admin`); see below for what the daemon does regardless |
| `grants` | subset of `sudo network media serial input` | capabilities a host turns into its groups |

| type | rank | home | nix | session | overridable |
|---|---|---|---|---|---|
| `admin` | 3 | persistent | untrusted | home-manager | home, nix, builders, session, grants |
| `member` | 2 | persistent | untrusted | home-manager | home, session, grants |
| `untrusted` | 1 | persistent | none | system-default | home, nix, session |
| `handover` | 0 | tmpfs | none | kiosk (firefox) | session |

Rules (`lib/registry.nix`, all `throw`s with the file name, so they fire when
*any* host reads the registry rather than only when someone builds the host
concerned):

- **Overrides only on the type's `overridable` axes.** "member, but nix =
  admin" is an admin with a misleading label, and the label is what people read.
- **Contradictions are refused**: a home-manager session with `nix = none`, an
  overlay store on a host without the guest-overlay feature, builders without
  nix admin.
- **Hosts narrow, never widen** (`registry/hosts.nix` `narrow.<user>`): builders
  true to false, grants to a subset, nix to a lower rank, and
  `localBuilds = false` -- accepted only where it already holds (below).
- **uids are never reused.** Removing someone is `removed = true;` with the file
  kept -- a tombstone -- because files on disk and in backups still carry the
  uid. A host listing a tombstoned user is an error.
- `sudo` in grants must agree with `wheel` in the host's groups.

**`registry/hosts.nix`** -- `hosts.<host>` lists users, the primary account
(what `my.<feature>.users` defaults to) and per-host group lists; `features.<host>`
records cross-host facts (builder role, ccache, CA, guest-overlay,
impermanence; yulee is listed as an unmanaged builder) that other machines need
without evaluating that host. They are facts, not switches: the switches are
still `my.*` in the host file.

`hosts.<host>.localPasswords` lists accounts whose password that host keeps for
itself (`passwd`, `users.mutableUsers` at its default) instead of using the
registry file's `passwordSecret`: a secret is encrypted to particular hosts'
keys, and a host that is not a recipient (dell-latitude, for benjamin's
victus-15-only secret) could not decrypt it. A client host with a builder key of
its own authorises it on a NixOS builder with
`my.remote-builder.server.extraKeys`, and reaches a peer in another tailnet by
FQDN through the peer's `address`.

**What the axes do today.** `my.users` on both hosts comes from the registry
(`lib/registry-users.nix`); the machinery is in `features/core/users/`, each
piece gated on some account using it, so both real hosts are unchanged:

| axis value | machinery |
|---|---|
| `home = tmpfs` | `tmpfs-home.nix`: a tmpfs (size `tmpfsSize`) mounted **per login**, bound to `user@<uid>.service` (RequiredBy/Before/PartOf, LazyUnmount) -- mounted before the user's manager starts, detached when it stops, the same lifetime logind gives `/run/user/<uid>`. logind kills those users' processes at logout (`KillUserProcesses` + `KillOnlyUsers`), so a straggler cannot keep the user, and with it the home, alive; lingering is refused. `createHome = false`: if the mount fails the home is root-owned, never persistent. Pins the uid. Re-login inside logind's 10 s `UserStopDelaySec` keeps the home. |
| `session = { kiosk = "<pkg>"; }` | `kiosk.nix`: a "Kiosk (<prog>)" wayland-session running `cage -s -- <pkg>` from the system pkgs (handover: firefox). Not enforced that the kiosk user *picks* it; that is the greeter's choice. |
| `nix = none` | `nix-access.nix`: left out of `nix.settings.allowed-users`. The list is only written on a host that has such a user; elsewhere it stays at its default `*`, so nix.conf is unchanged. `my.registry.nix.extraAllowedUsers` for service accounts. |
| `nix = untrusted` | asserted absent from `trusted-users` (by name, `*` or `@group`). |
| `nix = admin` | `nix-access.nix`: `trusted-users` is derived -- exactly the host's `nix = admin` accounts, plus root and `my.registry.nix.extraTrustedUsers` (non-people only). Host files no longer list trusted users. No preset uses it: people are untrusted, admins act through sudo. Remote builds reach a NixOS peer as its trusted `nix-ssh` account (`my.remote-builder.server`, upstream `nix.sshServe`: forced `nix-daemon --stdio`, builder key only); the wrappers that pin builders run their nix as root. |
| `nix = overlay` | `features/nix/guest-overlay`: a private store per guest -- OverlayFS of a frozen read-only btrfs snapshot of `/nix` (lower) and the guest's own upper layer, mounted per guest and bound over `/nix/store` in their sessions by `pam_namespace` (with their own `/etc/nix/nix.conf`: `local-overlay://`, opened directly as its owner). Every setting is theirs, own builders and substituters included, and nothing they build or fetch is visible outside their sessions. Refused by the shared daemon (allowed-users). Needs `homeActivation = "standalone"` with a home-manager session. Lever `my.guest-overlay.wrappers`: `hidden` (default; no setuid in guest namespaces, so no sudo/ping/lock-screen password check) or `shared`. |
| `home = impermanent` | refused, "not implemented yet" (needs impermanence). |

**What Nix enforces per user, honestly.** The daemon has two per-user lists,
allowed-users and trusted-users. `max-jobs` and the builders in
`/etc/nix/machines` are daemon settings applied to every build it accepts: an
untrusted user on galaxybook gets no local builds (max-jobs 0, for everyone)
and *does* get the remote builders (the daemon dispatches for him; he just
cannot name his own). So `builders = false` means "cannot pick builders",
and `narrow.<user>.localBuilds = false` is accepted only on a host whose
`features.<host>.localBuilds` is false or for a user without daemon access --
anywhere else it is refused rather than recorded as a promise nothing keeps.
`homeLib.<host>.facts.nix` reports what actually happens: `localBuilds`,
`remoteBuilds`, and per user `access`, `daemon`, `trusted`, `builds.local`,
`builds.remote`, `ownBuilders`. `localBuilds` and `builderClient` in
`registry/hosts.nix` are asserted against `nix.settings.max-jobs` and
`nix.distributedBuilds`.

**Deployed type.** With `my.registry.recordTypes.enable` (on for both
hosts; the option defaults to off), activation records each account as `<type> <home> <nix>` in
`/var/lib/nixos-users/<user>.type`, and a pre-switch check refuses (for
switch, boot and test, before anything changes) a move away from the
recorded line that is dangerous -- home leaving persistent (or going to
tmpfs), nix or type rank going down, or a record it does not recognise --
unless the user file says `acceptTypeChange = "<old type>-><new type>"`. A
missing record is just written, an unchanged one is a no-op, and consent is
inert once the new type is recorded. The rule lives once, in
`lib/registry.nix` `transition`; the shell only checks membership in the list
of admissible predecessors the registry enumerates.

`uid` is pinned in `users.users` for every account (checked against the live
uids before it was turned on). **Groups come from grants** and nowhere else:
`lib/registry.nix` `grantGroups` maps sudo -> wheel, network ->
networkmanager, media -> video + audio, serial -> dialout, input -> input,
in that order; a host takes a group away with `narrow.<user>.grants`, and a
`groups` key in registry data is refused. (Features may still add accounts
to their own groups.) **ssh:** a person logs in with their own key
(`sshKeys` in their file, `my.ssh.identityFile` on the client); the builder
key is root-only, because on a NixOS peer it logs in as the trusted
`nix-ssh`.

`tests/user-types-eval.sh` evaluates a synthetic galaxybook with a handover
and an untrusted user and the type record on, with builds disabled, and
checks the mount, logind, kiosk session, allowed-users, facts, the generated
check, and that the dangerous transitions and unenforceable narrowings are
refused.

## Optional pieces

| piece | where | requires | status |
|---|---|---|---|
| tuning lever `march` | `my.tuning.march` | the fork (selected automatically) | exists; on for both hosts |
| tuning lever `o3` | `my.tuning.o3.enable` | -- (`my.tuning.enable`; native mode without march) | exists; on for both hosts, with march |
| tuning lever `lto` | `my.tuning.lto.enable` | -- (`my.tuning.enable`; native mode without march) | exists; on for both hosts, with march |
| heavy (mold + ccache over the tuned set) | `my.tuning.heavy` | -- | exists |
| ccache | `my.ccache` (features/nix/ccache) | client half; `builder` half on NixOS builders | exists; to be split out of tuning's reach as its own optional feature |
| content-addressed derivations | `my.ca-derivations` (features/nix/ca-derivations; the "tuned" package policy is applied by tuning/ca.nix and needs march) | ca-derivations live on the evaluating daemon and every builder | exists |
| btrfs-layout (`/nix` its own subvolume) | `my.btrfs-layout` (features/core/btrfs-layout) | -- | exists; on for victus-15 (already a subvolume, `nix`); galaxybook needs the offline migration in the feature's header first |
| impermanence | `my.impermanence` (features/core/impermanence) + registry fact `features.<host>.impermanence` | btrfs-layout (rootSubvolume, persist), systemd initrd | exists; on for galaxybook4-pro360 |
| guest-overlay (per-guest overlay stores) | `my.guest-overlay` (features/nix/guest-overlay) + registry fact `features.<host>."guest-overlay"` | btrfs-layout | exists, off everywhere; eval-tested (`tests/guest-overlay-eval.sh`), VM test `checks.x86_64-linux.guest-overlay-vm` (partially passing, see design doc Next 11) |
| luks (TPM2 unlock, no PIN) | -- | -- | **planned** (lib/matrix.nix has its TODO entry) |

All levers default to off, and all off is plain upstream nixpkgs.

### Tuning

`tuning/` is machine-bound infrastructure, tied to the nixpkgs fork and to
generated per-host data, which is why it is not a feature.

```nix
my.tuning = {
  enable = true;               # LITERAL: flake.nix raw-imports it
  march = "meteorlake";        # or "znver3"; null for an untuned host. LITERAL.
  intraISACross.enable = true;   # generic cross/build-load fixes
  o3.enable = true;
  lto.enable = true;
  upstreamTools.enable = true;
  qtPatches.enable = true;     # meteorlake-specific; victus-15 leaves this off
};
```

**march is the only lever that selects the fork.** Which nixpkgs a host gets is
decided before the module system exists, so `flake.nix` reads `my.tuning.enable`
and `my.tuning.march` out of the host file by raw import (they must be literals;
an assertion catches any divergence from what the module system evaluates). The
fork is used only for `enable && march != null`. The reason: the fork's
cc-wrapper `setup-hook.sh` patch, whose bytes move stdenv's hash and rebuild
everything, only acts under IntraISACross, i.e. with march. `intraISACross`,
`upstreamTools` and `qtPatches` assert march: they are fixes for the split, or
for the fork's meteorlake qtbase. `enable = true, march = null` gets upstream
nixpkgs and keeps the levers that do not need the fork: `o3` and `lto` (in
native mode, below), heavy, refreshTool.

**march, lto and o3 are three independent levers.** Any combination evaluates
(`lib/matrix.nix`: `lto`, `o3`, `lto-o3` without march, `march-lto`,
`march-o3` with it).

**Why IntraISACross.** march declares `buildPlatform` *without* `gcc.arch` so it
differs from `hostPlatform`, making the build an intra-ISA cross rather than a
native one. That is what `tuning/overlays/upstream-tools.nix` keys off: natively
there is only one package set, so that overlay would alias *everything* to
upstream and silently delete the tuning. With the split, `pkgsBuildHost` is
plain x86_64 and byte-identical to upstream (build tools come from
cache.nixos.org) while `pkgs` stays tuned.

**lto and o3 without march** run natively on plain upstream nixpkgs. With no
split, build tools and the packages that run here are one package set, so
tuning a library also changes every build tool that links it. Two mechanisms
replace what the split did:

- `tuning/native-build-tools.nix`: a candidate in the runtime closure of a build
  tool (python3, perl, curl, git, clang, cmake, meson, glib, numpy...) is left
  untuned. So openssl, ncurses and util-linux stay as upstream builds them,
  and codecs, numerics, image and GUI libraries are tuned.
- the native branch of `tuning/overlays/upstream-tools.nix`: every attribute
  the classifier does not call host-runtime is aliased to the host's *untuned*
  package set (its own config and overlays, with o3/lto switched off), so it
  stays the all-off derivation and substitutes.

On galaxybook4-pro360, `lto` alone changes 541 derivations against `off`
(compared by output path), `o3` alone 814. None of them is gcc, binutils,
cmake, meson, ninja, python3, perl, clang, rustc or nodejs. 54 of the 541 are
python3Packages that reach a tuned library only through check inputs; scoped
package sets are not aliased. A library both a build tool and an application
link stays untuned natively, which is why march remains the stronger setting.
Natively zlib, xz, bzip2 and pcre2 cannot be tuned at all: the native stdenv
re-imports them from its bootstrap stage after every overlay.

**O3 and LTO apply only to what runs here.** The **host-runtime classifier**
decides which packages that is. It has three tiers: Tier 1 is the live system
closure, Tier 2 a cached eval heuristic, Tier 3 a live recompute. The caches
are one directory per host, read through the flake inputs
`tuning-cache-<host>`: `system-tier1.nix` and `system-tier2.nix` (the system's,
refreshed by the `cache-refresh` commands) and `users/<user>.nix` (each user's
own evidence, written by `tuning-refresh`), union-merged. They live in the repo
(`tuning/runtime-cache/hosts/<host>`) until the one-time
`scripts/tuning-cache-migrate.sh` moves them to `/var/lib/tuning-cache/<host>`
(needs `my.tuning.userCache.enable`); after that `scripts/tuning-cache-relock.sh`
gathers, relocks and distributes them, by hand.

**Which packages a lever may touch is an option:** `my.tuning.{o3,lto}.candidates`
(defaults in `tuning/candidates.nix`) and `my.tuning.{o3,lto}.exclude`.

**Per-user tuning.** A standalone home picks its own package set with the home
option `my.tuning = { march; lto; o3; }` (`"system"` = the host's, the default;
`true`/`false`; march may name an arch) and per-package levers
`my.tuning.packages.{o3,lto}` / `my.tuning.exclude.{o3,lto}` that apply inside
that user's set only (an explicitly listed name skips the classifier).
`homeLib.<host>.mkHome` builds the set as the eval matrix builds host variants
(`lib/user-tuning.nix`) -- still one nixpkgs pin -- and refuses a home whose set
cannot safely load the system's in-process code (`lib/surface-check.nix`): the
graphics driver, NSS, PAM, the locale and the system profile's plugins are walked
in the system's set, the home's packages in its own, and any library with the
same version but a different source or patch list fails the evaluation with a
full explanation. Measured: an untuned home on either march host is refused
(perl and sqlite carry cross-build patches in the system's IntraISACross set);
lto/o3 choices pass. `tests/user-tuning-eval.sh`.

## Rebuilding

### Admin (system)

The rebuild wrappers are generated by `features/nix/remote-builder/wrappers.nix`
from `my.remote-builder.client.peers` and the host's own name (the hand-written
versions hardcoded `#galaxybook4-pro360`, so a cloned host would have rebuilt
the machine it was copied from). On galaxybook4-pro360:

```sh
nixos-rebuild switch          # evaluate on victus-15 (the evalWorker), build + activate here
nixos-rebuild-victus-15       # the same, explicitly; --local-eval to evaluate here
nixos-rebuild-victus-15-local-eval  # evaluate here, build on victus-15 only
nixos-rebuild-yulee           # evaluate here, build on yulee only
nixos-rebuild-local           # evaluate and build here, cache.nixos.org only
nix-shell-<peer> / nix-shell-local   # nix-shell with the same restrictions
```

- **Plain `nixos-rebuild` is shadowed** (`hiPrio`) when an `evalWorker` is set:
  bare `switch`/`boot`/`test`/`build` copy the checkout (uncommitted edits
  included) to the peer with `nix flake archive`, evaluate the toplevel there
  (~19 s against ~65 s on the laptop), copy back only the missing `.drv`s, then
  build *here* -- the peer cannot substitute this host's tuned outputs -- and
  activate. Any other action, any extra argument, an unreachable peer or a
  failed copy falls back to the real `nixos-rebuild`. A real evaluation or
  build error is reported, not retried.
- **`nixos-rebuild-<peer>` restricts the build phase, not evaluation.**
  nixos-rebuild passes no flags to its `nix eval`, so import-from-derivation
  builds during evaluation (doom-intermediates) go to the whole
  `/etc/nix/machines` list. To really exclude a peer, set
  `my.remote-builder.client.peers.<name>.enable = false`.
- **Every wrapper pins its substituters** (`cache.nixos.org` plus the named
  peer). Omitting the flag means "inherit the system list", which can name a
  machine that is down, and an `ssh-ng://` substituter fails with the same
  message as a builder.
- **`nixos-rebuild-local` is for config-only updates.** No builders and only
  cache.nixos.org, deliberately.

`scripts/nixos-rebuild-switch.sh [host]` runs `sudo nixos-rebuild switch` with
build logs and prints one root error instead of the cascade;
`scripts/nixos-rebuild-progress.sh [host]` watches its progress from another
terminal. The rest of `scripts/` are one-off builder bootstrap and diagnostic
helpers (mostly for yulee).

Runtime cache:

```sh
cache-refresh                # runtime cache for every host (tier1 over ssh)
cache-refresh-local          # just this host, after a switch
cache-refresh-<host>         # just that host
```

The `cache-refresh` commands run `git add` at the end, and that is load-bearing:
a dirty tree's flake evaluation only sees files git knows about, so an untracked
cache file is written, reported as written, and then silently ignored. Every
cache file lands in the checkout the command runs in; another host's Tier 1 is
read over ssh (`my.tuning.refreshTool.sshTargets` -- victus-15 is reachable,
the laptop runs no sshd, so from victus its Tier 1 is skipped).

Per-feature `update.sh` scripts bump pinned upstreams
(`features/apps/claude-code/update.sh`, `features/apps/claude-desktop/update.sh`).

`nix flake check` is the one-command gate: forcing each toplevel evaluates its
assertions, `_meta`'s included. It triggers Unstraightened's IFD on any change
that moves the package set, so run it with a reachable builder or
`--builders ''`.

`scripts/eval-matrix.sh` keeps the optional pieces optional. It evaluates, and
never builds, synthetic variants of each real host defined in `lib/matrix.nix`:
every piece of [Optional pieces](#optional-pieces) off (plain upstream
nixpkgs), each alone, all on, the combinations that matter (`lto-o3`,
`march-lto`, `btrfs-impermanence`, ...), and the combinations that are invalid
by design (impermanence or guest-overlay without btrfs-layout, the
fork-only tuning levers without march, `ca` "tuned" without march, march
without `enable`, btrfs-layout on dell-latitude's ext4 root), which must FAIL
with the assertion that names the reason -- the script checks the message, so
failing for another reason is reported too. A new piece is one entry in
`lib/matrix.nix`'s `pieces`. Patterns select a subset
(`scripts/eval-matrix.sh 'dell-latitude/*' '*/off'`; `--list` shows them);
an IntraISACross host's variants take about a minute each, run one at a time.
With `--with-emacs`, the `host` variant must equal the real host's toplevel
(checked), which is how the matrix is known to be faithful. Run it after any
change to tuning, ccache, CA, the btrfs/impermanence/guest features or `_meta`.

`checks.x86_64-linux.guest-overlay-vm` (tests/guest-overlay-vm.nix) boots
guest-overlay in a VM whose `/nix` is a btrfs subvolume, on plain upstream
nixpkgs: snapshot, overlay mount, guest sessions (su and a tty login, the
user manager included), `nix store info`, a build and a GC in the guest
store, rebase with copy-up after an admin GC, and a "switch" during a session
(kept lower, rebase at logout). Needs kvm, so it builds on a builder:
`nix build -L .#checks.x86_64-linux.guest-overlay-vm`.

### Users (home)

Standalone accounts (see [Who activates a home](#who-activates-a-home)):

```sh
home-manager switch --flake ~/config/home#<user>@<host>
```

or the **planned** `hm-switch` wrapper, which adds advisory checks (lock
consistency with the system flake, the generation's epoch against the system's
history) before switching. Users are untrusted in the daemon at that point, so
they substitute and use what the system has built, but cannot pass
`--builders` or extra substituters.

## Adding things

### A feature

1. `mkdir features/<category>/<name>` (an existing category, or a new one; the
   leaf name must be unique)
2. `nixos.nix` -- declare `options.my.<name>.enable`, wrap the body in
   `lib.mkIf cfg.enable`; declare `my.internal.features.<name>` if it requires
   other features or fills a role
3. `home.nix` if it has a user-side half -- gate on `osConfig.my.<name>.enable`
4. `packages.nix` if it installs anything, and have `nixos.nix` read it, so the
   feature works for someone who does not use this repo's conventions
5. its own `flake.nix` and a `feat-<name>` input in the root only if it needs
   an external input (mind the two-level `follows`)
6. `git add` it -- untracked files are invisible to the flake, and the symptom
   is a bogus "option does not exist"
7. enable it in a host file

Options only for what actually varies. Most features have nothing but `enable`.

### A user

1. `registry/users/<name>.nix` with a fresh `uid` (never one a tombstone
   holds), a `type`, a `shell` attribute name and a `passwordSecret`
2. the password hash as `age/hashed-password-<name>.age`, with recipients in
   `secrets.nix`
3. add the name to `hosts.<host>.users` in `registry/hosts.nix` (and per-host
   `groups` if the defaults are not right)
4. `nix eval .#registry.effective` to check the result
5. the user creates a home repo with `nix flake init -t github:R0K0R/nixos#home`;
   the system activates their home until their file says
   `homeActivation = "standalone"`

Removing a user: set `removed = true;` in the file, keep it, and drop the name
from `registry/hosts.nix`.

### A host

1. Copy an existing `hosts/<name>/default.nix`, change `networking.hostName`
2. `nixos-generate-config` for `hardware-configuration.nix`
3. Register it in `flake.nix` (`nixosConfigurations.<name> = mkHost "<name>"`)
   and give it an entry in `registry/hosts.nix` (users, primary, facts)
4. **Seed the runtime cache before the first evaluation** if it is tuned -- see
   below

## Gotchas

**`my.packages.extra` must be a literal.** Tier 3 reads it from the host file by
raw import, without a module evaluation, so it cannot resolve `mkIf`/`mkMerge`.
Wrapping the *leaf* fails loudly; wrapping the *parent* returned an empty anchor
set silently until an explicit `_type` guard was added. `my.tuning.enable` and
`my.tuning.march` have the same constraint for the same reason.

**Package collisions are silent on two of three targets.**
`environment.systemPackages` and `users.users.<n>.packages` set
`ignoreCollisions = true` -- first in list order wins, with only a build-log
warning. `home.packages` hard-errors. Identical derivations dedupe and cost
nothing.

**`my.claude-desktop.cowork` pulls 151 untuned packages** via qemu -- its own
glibc, systemd, gtk4 and pipewire, measured at 74% of every upstream-identical
package in the system. It is opt-in and deliberately not implied by `enable`.

**Seed the runtime cache before evaluating a new tuned host.** Not because
Tier 3 is slow -- it isn't. Measured:

| | |
|---|---|
| cold cache, IFD disabled (pure eval) | 12.8s |
| warm Tier 2 copied from a sibling | 30s |
| cold cache, IFD on, builder unreachable | >20 min, never completed |

With no `tier{1,2}/<host>.nix`, `hasWarmCache` is false, so `upstream-tools`
refuses to alias anything to upstream. The package set then differs from every
existing host -- a different Emacs, so a different `doom-intermediates`, so
Unstraightened's import-from-derivation has to **build** it during eval. If a
remote builder is down, that hangs in SSH `SYN-SENT` while `nix` sits at ~2% CPU
blocked on the daemon socket. It looks like a slow evaluation and is not one.

Copy a sibling host's tier2 file and change the `host` field: an identical
package set means the IFD output is already in the store.

**Diagnosing a "slow" eval.** Check CPU first. If `nix` is near-idle it is
blocked on the network, not computing -- `ps -o stat,%cpu,wchan -p <pid>` and
`ss -tnp | grep :22`. `--option allow-import-from-derivation false` cleanly
separates evaluation cost from build cost, and `--builders ''` keeps a dead
builder out of the picture.

**nixd needs IFD disabled.** Pointing it at `nixosConfigurations.<host>.options`
otherwise lets nix-doom-emacs-unstraightened's import-from-derivation trigger a
`doom-intermediates` build from the editor -- once measured at 226 minutes. Run
it with `allow-import-from-derivation = false`; you lose completion inside the
Emacs feature and nothing else.

**`nix.settings` merges across features.** The `nix-settings` feature sets
substituters at `mkDefault` so `remote-builder`'s peer list wins where both are
on.
