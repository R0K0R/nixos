# Haku unified settings — design

> **Status: design, not yet implemented.** This is the agreed blueprint for a single settings
> system that replaces the scattered hardcoded values, inline `set` configs, and the upstream rofi
> menus. Build order is in [§10](#10-migration-plan).

## 1. Goal & the one hard principle

One place to configure everything tunable, edited from a keyboard-driven TUI, applied **live** where
possible — no more rebuild-to-change-a-pixel, no more `sed -i` menus.

The one principle everything follows, because this is NixOS:

- **runtime** values (colours, sizes, fonts, timeouts, behaviour toggles, EQ, decoration/blur/keystone
  params, dock feel, monitor scales…) → live in the store, change instantly.
- **build** values (which packages, services, the kernel, the compositor *source* patch, `modKey`
  baked into generated Lua…) → stay Nix-only. The settings system *surfaces* them (read-only, with a
  **needs-rebuild** badge) but can never make them live. That's not a limitation to fight; it's NixOS.

Every setting therefore carries a `scope` that is exactly one of these two.

## 2. Architecture at a glance

```
 features/*/hearth.nix            per-feature schema fragments  (modular: a feature owns its slice)
        │  merged + rendered by Nix
        ▼
 schema.json   ← generated, read-only, carries every key's default (regenerated each rebuild)
        │
        ▼
 ┌─────────────┐   overrides.json  (only what YOU changed — survives rebuilds, flat dotted keys)
 │  haku-settings (TUI / CLI) │  the ONLY writer
 └─────────────┘
        │  validate → materialise → signal
        ▼
 settings.json   (effective = deep-merge(defaults, overrides), NESTED — what every consumer reads)
 settings.signal.json   ({version, changed:[…keys], ts} — the "git diff" of what just changed)
        │  a watch fires
        ▼
 consumers: notifcenter QML · hyprland Lua · dock.sh · waybar · bonfire …
            each owns key-prefixes, reloads only the parts that changed
```

Files live under **`$XDG_STATE_HOME/haku/`** (i.e. `~/.local/state/haku/`), the generalisation of
today's `~/.local/state/haku_theme/`:

| file | writer | consumers | notes |
|---|---|---|---|
| `schema.json` | Nix (generated) | the TUI + materialiser | metadata registry **incl. each key's default** (§3). Read-only. |
| `overrides.json` | `haku-settings` | the materialiser | **only user-changed keys**, flat. Never clobbered. |
| `settings.json` | `haku-settings` | **everyone** | effective, nested, `jq`-friendly (§4). |
| `settings.signal.json` | `haku-settings` | everyone (watch) | the change diff (§5). |

> Implemented by the standalone **`hearth`** engine (`~/Documents/projects/hearth`,
> `github:sihooleebd/hearth`) — `haku-settings` is hearth with the Haku schema + TUI on top.

**Why flat schema but nested store:** a flat registry (`"a.b.c": {…}`) makes each setting an
independent record — trivial to add, delete, or merge from fragments. A nested store reads cleanly,
mirrors the TUI tree, and `jq '.panel.geometry.width'` just works in a shell script.

## 3. The setting record — the modular unit

Each setting is one self-contained record in `schema.json`, keyed by its **dotted path**. The key is
the address: it is the store location, the TUI tree position, *and* the diff identity, all at once.

```jsonc
"panel.geometry.width": {
  "type":    "int",          // REQUIRED — drives the editor + validation (§3.2)
  "default": 800,            // REQUIRED — the value when not overridden (owned by Nix)
  "label":   "Panel width",  // REQUIRED — short name shown in the TUI
  "help":    "Width of the notification-centre panel.",   // one–two sentence doc
  "tier":    "common",       // common | advanced     (default: common)  — advanced = "hidden files"
  "scope":   "runtime",      // runtime | build        (default: runtime) — build ⇒ needs-rebuild badge
  "reload":  "panel",        // optional — reload domain; defaults to the first key segment
  "constraints": { "min": 480, "max": 1200, "step": 10, "unit": "px" },
  "order":   10,             // optional — sort within its group (default: alphabetical by label)
  "visibleIf": null,         // optional — {"key":"…","equals":…} to show only when another is set
  "deprecated": false        // optional — true ⇒ TUI hides/warns; delete the record next cycle
}
```

### 3.1 Field reference

| field | required | meaning |
|---|---|---|
| *(map key)* | ✓ | dotted path, segments `[a-z0-9_]+`, e.g. `hyprland.decoration.rounding`. |
| `type` | ✓ | one of §3.2; selects the editor + validator. |
| `default` | ✓ | default value, correct JSON type for `type`. |
| `label` | ✓ | short human name. |
| `help` | ✦ | one/two sentences. This is the documentation — it shows in the TUI. |
| `tier` | | `common` (default) or `advanced`. |
| `scope` | | `runtime` (default) or `build`. |
| `reload` | | domain tag for routing; defaults to the key's first segment. May be a list. |
| `constraints` | | type-specific (§3.2). |
| `order`, `visibleIf`, `deprecated` | | optional polish, as above. |

### 3.2 Type system (add a type ⇒ add one renderer; nothing else changes)

| `type` | editor | constraints | default example |
|---|---|---|---|
| `bool` | toggle | — | `true` |
| `int` | stepper / slider | `min` `max` `step` `unit` | `16` |
| `float` | slider | `min` `max` `step` `precision` `unit` | `0.17` |
| `string` | text field | `pattern` `maxLength` `multiline` | `"kitty"` |
| `enum` | single-select | `options`: `["a","b"]` or `[{"value","label"}]` | `"balanced"` |
| `color` | colour picker | `alpha` (bool) | `"#16ffffff"` |
| `font` | family picker | `monospace` (bool) | `"DepartureMono Nerd Font"` |
| `path` | path field | `kind`: `file`\|`dir` | `"~/Pictures"` |
| `list` | list editor | `item`: a nested type spec | `["sonora","kitty"]` |
| `keybind` | chord capture | — | `"SUPER, D"` *(later)* |

The TUI is **100% generic over `type`** — there is no per-setting UI code, which is what makes the
whole thing modular. Validation is likewise driven by `type` + `constraints`, enforced by the writer
before anything is persisted.

### 3.3 Groups / the tree

The TUI tree is derived from the dotted keys (`panel.geometry.width` → `Panel ▸ Geometry ▸ Panel
width`), segments humanised. Optional nicer labels/order/icons for intermediate nodes come from an
optional `groups` block in the schema:

```jsonc
"groups": {
  "panel":            { "label": "Notification centre", "order": 10, "icon": "󰎟" },
  "panel.geometry":   { "label": "Geometry", "order": 20 },
  "hyprland":         { "label": "Window manager", "order": 30 }
}
```

## 4. The store (`settings.json`) & layering

```jsonc
{
  "_version": 42,
  "panel":    { "geometry": { "width": 820 }, "colors": { "tile_bg": "#1effffff" } },
  "hyprland": { "decoration": { "rounding": 20 } }
}
```

- `settings.json = deep-merge(defaults-from-schema, overrides)`, nested. **Consumers read only this file.**
- `overrides.json` is flat and holds **only** what the user changed:
  `{ "panel.geometry.width": 820, "hyprland.decoration.rounding": 20 }`.
- Rebuild behaviour: Nix regenerates `schema.json` (with new defaults); the materialiser re-merges. New/changed
  **defaults** flow through; **overridden** keys are untouched. Deleting a schema key prunes it from
  the effective store and ignores any stale override — clean deletions.
- `_version` is a monotonic integer bumped on every write (reliability net, §5).

## 5. The change signal — "git diff for config"

The writer is the only mutator. On any change it:

1. **validates** the new value against `schema.json` (type + constraints); rejects bad input.
2. writes `overrides.json`, then **materialises** `settings.json` atomically (temp-file + `rename`).
3. computes the **diff** (effective-value changes) and bumps `_version`.
4. writes `settings.signal.json` atomically — *this file changing is the dispatch*:

```jsonc
{ "version": 42, "changed": ["panel.geometry.width", "hyprland.decoration.rounding"], "ts": 1760413200 }
```

### Consumer contract (identical in every language)

1. **Declare the key-prefixes you own** — panel → `["panel"]`, hyprland-lua → `["hyprland"]`,
   dock → `["dock"]`, waybar → `["panel.bar","theme"]`, …
2. **Watch `settings.signal.json`.** On a fire, read `changed[]`; for every entry under one of your
   prefixes, re-read that key from `settings.json` and apply it (§6).
3. **Track the last `version` you handled.** If it jumped by more than one (you missed a fire during
   a restart), reload your whole prefix. Immediacy from the signal; correctness from the version.

**Transport:** the signal **file + a watch** is the source of truth — it's the one thing all three
languages do painlessly and it carries the payload. `panelbus` may *additionally* push an instant
in-process ping to the panel, but nothing depends on it.

## 6. Per-consumer reload recipes (grounded in the current code)

**notifcenter QML** (`features/notifcenter/shell.qml`) — replace the open-time `colors.css` poll with
a `FileView`/watch on `settings.json`; bind the design tokens + dimensions to it so most changes
reapply by QML reactivity alone. Prefixes: `panel`, `theme`.

**hyprland Lua** (`features/hyprland/home.nix`) — on a `hyprland.*` change, `hyprctl eval
'hl.config({…})'` with the new values; the decoration / blur / keystone / animation / gaps / gesture
keys are already documented as live-tunable this way. Keybinds + window-rules need a config reload.
Prefix: `hyprland`.

**dock** (`features/sidedock/dock.sh`) — already reads its feel constants fresh each invocation; point
those reads at `settings.json` (`jq`) and re-render on a `dock.*` signal. Prefix: `dock`.

**waybar / rofi / cava** — these consume `@accent_color` from `colors.css` today; keep that bus for
colour, and have the materialiser *also* regenerate `colors.css` from the `theme.*` keys so the
upstream consumers need no change. Prefix: `theme`.

**bonfire** — audio already has its own live `state.json` + CLI. The settings system owns *defaults*
(`audio.*`) and drives them via the `bonfire` CLI; it does not duplicate bonfire's runtime state.

## 7. Declaring settings in Nix (the modular source)

Each feature drops a fragment, auto-discovered like the existing submodule pattern:

```nix
# features/notifcenter/hearth.nix   (named hearth.nix, NOT settings.nix — that name is already taken
#                                    by other features, e.g. features/dms is DMS's own config)
{
  "panel.geometry.width" = {
    type = "int"; default = 800; label = "Panel width";
    help = "Width of the notification-centre panel.";
    constraints = { min = 480; max = 1200; step = 10; unit = "px"; };
  };
  "panel.colors.tile_bg" = {
    type = "color"; default = "#16ffffff"; label = "Inactive tile";
    help = "Background wash behind an un-pressed control tile.";
    constraints.alpha = true;
  };
}
```

Nix merges all `features/*/hearth.nix` → writes `schema.json`. Adding a setting =
one record in the owning feature; deleting = remove it. `rm -r features/x` takes its settings too.
(Adding a *setting* is a rebuild — you're editing the flake anyway; **changing a value** is always
live. That is the correct line.)

## 8. The TUI (`haku-settings`)

Python + **Textual** (in nixpkgs; same language as bonfire). yazi/ranger-style miller columns:

```
 Appearance      │ › Panel            │  Panel · width
 Panel         › │   Geometry       › │  ──────────────
 Audio           │   Colors           │   820  ▸ [480 ──●──── 1200] px
 Window manager  │ · Advanced (3) ⋯   │   default 800 · live
 System ⚙        │                    │
 /width_          ← fuzzy search      │   ⏎ edit  d reset  . advanced  u undo
```

- tree from `schema.json`; **advanced = hidden files**, toggled with `.` (like `ls -a`).
- `/` fuzzy search across *every* key so "exhaustive" never means "lost".
- editors are generic per `type`; `scope:build` rows show a **⚙ needs rebuild** badge and queue into a
  "pending rebuild" list instead of applying live.
- editing writes `overrides.json` via the writer, which materialises + signals; the TUI shows the
  live value echo back.
- also exposes a non-interactive CLI: `haku-settings get <key>` / `set <key> <value>` / `reset <key>`
  — so keybinds and scripts can poke settings too.

## 9. Known hard cases (resolve during implementation)

1. **Upstream shell scripts that `sed -i` their own configs** (the wrapped `hakuspace` package —
   theme/wallpaper/dockbar/cava). They mutate `config.rasi`, `dockbar/config`, `colors.css`
   themselves. Options: (a) let them keep owning *their* files and have the materialiser treat
   `colors.css` as a generated *output* of `theme.*`; or (b) intercept the few menu entries we care
   about and route them through `haku-settings`. Likely a mix — don't fight the upstream for things
   it already does well (theme switching), do co-opt the "terrible" bits.
2. **Values that are both runtime and buildtime.** e.g. `border_size` also feeds the touch-gesture
   strip formula at build; `modKey` is interpolated into the generated Lua. Rule: if a Nix-side
   consumer needs the value at build time, it stays `scope:build` (the store may *mirror* it
   read-only for display, but the build is the source of truth). Don't half-move these.
3. **Three readers, one schema.** Nix (defaults/types), QML (panel), POSIX shell + Lua (everything
   else). JSON keeps data portable; the signal is a plain file. The only real cost is a tiny
   read+apply adapter per consumer — acceptable, and each is small.

## 10. Migration plan

1. **Plumbing first** — the store + materialiser + `settings.signal.json` + the `haku-settings`
   get/set CLI + one generic watcher helper. No UI yet; prove the loop with two or three keys.
2. **First real consumer** — move the notifcenter design tokens + geometry behind `panel.*`; wire the
   QML watch. This is the densest, highest-value, already-live-ish surface.
3. **Compositor feel** — `hyprland.{decoration,blur,keystone,animation,gaps,gesture}.*` via
   `hyprctl eval`. Proven live, big payoff.
4. **Dock feel** + **audio defaults** + the values behind the old rofi menus.
5. **The TUI** (Textual) on top of the now-populated schema.
6. **Widen** feature by feature until the hardcoded surface is gone.
