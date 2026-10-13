# Rebrand: Haku/hakuspace → bonfire 🔥

> **Status: in progress.** The desktop is being rebranded to a campfire theme. Every component becomes
> an element of the fire. `hakuspace` (an unmaintained upstream shell R0K0R nixified) is being **vendored
> into this flake and renamed** — 100% removal, nothing left pointing at `R0K0R/hakuspace`.

## Name map

| component | old | new |
|---|---|---|
| the system / identity | Haku / hakuspace | **bonfire** |
| audio engine | bonfire | **lyre** |
| settings store | hearth | **hearth** (keep) |
| notification centre | notifcenter | **flare** |
| dock | sidedock | **pyre** |
| launcher / menu | hakumenu | **flint** |
| theme / accent + state | haku_theme | **glow** |
| the shell (forked hakuspace) | hakuspace | **bonfire** (the repo `sihooleebd/bonfire` = the shell = the desktop) |

Collisions to respect: `bonfire` the *name* must leave the audio engine (→ lyre) before the system can
take it — that includes the null-sink literally named `bonfire` in lyre's graph and the `bonfire` CLI.

## Phases (ordered by ripple; eval + commit per phase)

1. **logo groundwork** *(done)* — track `logo.txt` at the flake root; `features/fastfetch` shows it.
2. **lyre** *(done)* — audio engine renamed everywhere: the repo (`sihooleebd/lyre`), its package +
   sink constant + CLI + socket (`~/.config/lyre`, `lyre.sock`, `LYRE_*`), the flake input,
   `features/lyre`, `my.lyre`, and every `lyre …` call + the `.lyre` status key in the panel.
3. **flare** *(done)* — `features/flare`, `my.flare`, the quickshell config + service `haku-notif`→
   `flare` (incl. hakuspace's waybar callers), the panelbus handler `notif`→`flare`.
4. **pyre** *(done)* — `features/pyre`, `my.pyre`, the panelbus handler `dock`→`pyre`. (The script is
   still `dock.sh` and the "dock" *concept*/window-tag is unchanged — pyre is the feature/brand name.)
5. **bonfire (the shell)** *(the biggest)* — fork + rebrand the unmaintained hakuspace shell into
   `sihooleebd/bonfire` (the repo = the shell = the desktop).
   - **Stage A** *(done)* — forked `R0K0R/hakuspace` → `sihooleebd/bonfire` (155 files, history kept),
     repointed `features/hakuspace/flake.nix` at it. Eval is byte-identical (clean de-R0K0R).
   - **Stage B** *(done)* — renamed internals in the bonfire repo (`programs.hakuspace`→`bonfire`,
     `hakumenu`→`flint`, `HAKU_*`→`BONFIRE_*`, `haku_theme`→`glow`, `hakuspace-control`→`bonfire-control`;
     95 files, 0 non-attribution `haku` left, original author credited). Flake side:
     `features/hakuspace`→`features/bonfire`, `my.hakuspace`→`my.bonfire`, `feat-hakuspace`→`feat-bonfire`,
     the `$out/share/hakuspace`→`bonfire` package paths, the panel's `haku_theme` reads + `HAKU_*` env
     vars, and the keystone patch's layer match (→ exact `"flare"`, which the flare rename had left
     mismatched). A guarded `bonfireRebrandMigration` activation carries the live theme
     (`haku_theme`→`glow`) + control dir (`~/hakuspace-control`→`~/bonfire-control`) across, so a rebuild
     never resets them. Docs (README/SETTINGS identity) land in phase 6.
6. **identity + logo everywhere** — README/MOTD/`tuigreet`/**plymouth**/fastfetch/hyprlock/the panel
   header, all carrying the bonfire logo. Rename `sihooleebd/nixos` doc identity to bonfire.

## Handoff

- **You (GitHub):** rename the repos as each phase needs it — `bonfire`→`lyre` (phase 2); the shell
  gets vendored so no new repo needed (phase 5); `hearth`/`nixos` keep their names unless you want to
  rename `nixos`→`bonfire`.
- **Me (code):** everything else, phase by phase, `nix eval` after each, commit per phase, you rebuild
  to validate (the shell is your live desktop — don't batch phase 5 blind).

## Gotchas

- `my.<feature>` renames ripple into `hosts/*/default.nix` + any cross-feature `osConfig.my.*` reads.
- The feature **walk is by directory name**, so `git mv features/<old> features/<new>` + rename the
  `options.my.<old>` inside is the unit of work; miss the option rename and eval fails loudly (good).
- State-dir renames (`haku_theme`→`glow`) need a one-shot migration in the activation, guarded so a
  rebuild never resets a populated theme.
