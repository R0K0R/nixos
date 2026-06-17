# 44 — breeze-icons: qrcAlias host binary runs on builder (waitpkg crash) + requiredSystemFeatures bootstrap deadlock

## Symptoms

Build of `breeze-icons` on yulee (AMD znver3) exits with SIGABRT:

```
Incompatible processor. This Qt build requires the following features: waitpkg
```

When guarded with `requiredSystemFeatures = ["galaxybook-local-qt6"]`, the build
instead fails on GB4 with:

```
required (system, features): (x86_64-linux, [galaxybook-local-qt6])
Reason: missing system features
Required features: {galaxybook-local-qt6}
Available features: {benchmark, big-parallel, gccarch-meteorlake, kvm, nixos-test}
```

And `--option system-features "... galaxybook-local-qt6"` on the command line is
silently swallowed:

```
warning: ignoring the client-specified setting 'system-features', because it is
a restricted setting and you are not a trusted user
```

## Root cause A — qrcAlias is a host binary that runs during its own build

breeze-icons compiles a small helper (`qrcAlias`) from C++ **using the host
compiler** (here: meteorlake-tuned gcc) during its own build phase. That binary
is not installed anywhere; it is invoked immediately in the same CMake phase as a
build tool to alias Qt resource IDs.

Nix's cross model distinguishes *native* (runs on build machine) from *host*
(runs on the target). Anything that must run during the build should be compiled
for the build machine and placed in `nativeBuildInputs`. But this is an internal
CMake step — there is no separate derivation and no nativeBuildInputs hook. Qt
compiled the helper with the host compiler because it was convenient; now the
binary can only execute on the host architecture.

When yulee (AMD, no `waitpkg`) tries to build `breeze-icons`, the host compiler
produces a meteorlake binary. Qt's startup check (`QCoreApplication` init)
immediately detects the unsupported instruction set and aborts.

**Pattern:** Any package that (a) has a CMake "compile-and-run" helper step, (b)
inherits its compiler from Qt's host toolchain, and (c) has that helper target a
CPU feature the build machine lacks will exhibit this crash on any non-meteorlake
builder. breeze-icons is one; look for others in KDE packages that use
`qt_internal_add_resource` or similar macros with alias generation.

**Fix (short-term):** `preferLocalBuild = true` so the build runs on GB4 where
the resulting binary can execute.

**Fix (long-term):** The breeze-icons CMake should compile this helper with
`CMAKE_CROSSCOMPILING_EMULATOR` or detect the cross case and use a pre-built
host tool. Upstream Qt has a mechanism (`QT_TOOL_TARGET`) for this but breeze-icons
doesn't use it.

## Root cause B — requiredSystemFeatures bootstrap deadlock

To permanently prevent breeze-icons from being dispatched to yulee, the overlay
added:

```nix
requiredSystemFeatures = (old.requiredSystemFeatures or []) ++ ["galaxybook-local-qt6"];
```

And the NixOS module added:

```nix
nix.settings.system-features = ["galaxybook-local-qt6"];
```

This creates a circular dependency:

- `galaxybook-local-qt6` enters `system-features` only after `nixos-rebuild switch`
  writes a new `/etc/nix/nix.conf` and the daemon is reloaded.
- `nixos-rebuild switch` requires building the new toplevel.
- Building the toplevel requires building `breeze-icons`.
- `breeze-icons` has `requiredSystemFeatures = ["galaxybook-local-qt6"]`.
- The current nix.conf doesn't have `galaxybook-local-qt6` → no machine (local
  or yulee) accepts the derivation → deadlock.

**The general rule:** `requiredSystemFeatures` in a NixOS config that also sets
`nix.settings.system-features` for the first time is always a bootstrap deadlock.
The feature is not "real" until after the switch that introduces it.

**Fix:** Use only `preferLocalBuild = true` during the bootstrap switch. Add
`requiredSystemFeatures` back afterward if you need the hard guarantee.

Alternatively, add the feature to `/etc/nix/nix.conf` manually before building:

```sh
sudo sh -c 'echo "extra-system-features = galaxybook-local-qt6" >> /etc/nix/nix.conf'
sudo systemctl restart nix-daemon
```

## Root cause C — system-features is a restricted nix setting

`system-features` cannot be overridden on the command line by untrusted users:

```
warning: ignoring the client-specified setting 'system-features', because it is
a restricted setting and you are not a trusted user
```

The nix daemon owns `system-features`; it reads it from its own `/etc/nix/nix.conf`
at startup. Only users listed in `trusted-users` (root, @wheel, or explicit names)
can pass `--option system-features` and have it respected.

This means you cannot work around root-cause B by passing `--option system-features`
unless you are already a trusted user in the *deployed* config — which may not
yet be the case if the config is still being bootstrapped.

## Summary of interactions

```
breeze-icons host binary → must run on meteorlake hardware
  → preferLocalBuild = true         (OK: GB4 has max-jobs = auto)
  → requiredSystemFeatures          (DEADLOCK if feature not yet deployed)

--option system-features            (IGNORED: restricted setting, untrusted user)

nix.settings.system-features        (only active after nixos-rebuild switch)
```

## Applied fix

Removed `requiredSystemFeatures` from the `localQt6` overlay helper; kept only
`preferLocalBuild = true`. After the first successful switch, `galaxybook-local-qt6`
will be in the deployed nix.conf and `requiredSystemFeatures` can be restored as
a hard guard if desired.
