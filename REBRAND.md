# Rebrand: Haku/hakuspace → bonfire 🔥

> **Layout note.** Written while this repo was a NixOS system flake; it is now a standalone
> home-manager repo (see README.md). `features/<x>` paths below are historical: the user-level
> ones are `modules/{desktop,shell,editor,apps}/...`, the system-level ones moved to the system flake.

> **Status: complete** (2026-10-14). The desktop is a campfire theme — every component an element of
> the fire. The unmaintained `hakuspace` shell was **forked to `github:sihooleebd/bonfire`** and renamed
> end to end; nothing points at `R0K0R/hakuspace` any more. All six phases below are done. Deploy with a
> `nixos-rebuild switch` (it rebuilds the shell package, runs the theme-state migration, and recompiles
> Hyprland for the keystone patch).

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
6. **identity + logo everywhere** *(done)* — README retitled `bonfire` + the component list refreshed
   (flare/pyre/lyre/flint/glow, no more stale "bonfire audio engine"); flake `description`; `tuigreet`
   `--greeting`; fastfetch already carries the fire logo; **plymouth** is now a custom `bonfire` script
   theme (the braille mark rendered to a fire-gradient PNG via `features/boot/plymouth-logo.py`, a
   breathing-ember pulse, ships `script.so` for the initrd — dell-latitude has no LUKS so there's no
   password dialog to honour). SETTINGS.md writer name corrected to `hearth`.
   - *Deferred (minor polish):* a `hearth` MOTD (the fish greeting already runs fastfetch on every
     terminal), a hyprlock identity label, and a bonfire marker in the flare panel header.

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
