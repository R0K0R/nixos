# bonfire 🔥 -- Benjamin's home

The home-manager configuration for the account `benjamin`, as a standalone repo built on the
system flake's `homeLib`. It holds the **bonfire** desktop: a campfire-themed Hyprland session where
every component is an element of the fire -- the [`lyre`](https://github.com/sihooleebd/lyre) audio
engine, the [`hearth`](https://github.com/sihooleebd/hearth) settings store, the `flare`
notifications, the `pyre` dock, the `flint` launcher and the `glow` theme, all on the `bonfire` shell
([sihooleebd/bonfire](https://github.com/sihooleebd/bonfire)).

It used to be a whole NixOS system flake (three hosts, a nixpkgs fork's tuning backend, the cross-build
notes). The system half now lives in the admin's flake,
[`github:R0K0R/nixos`](https://github.com/R0K0R/nixos) (the `multiuser` branch); this repo keeps only what
lives under `$HOME`. It outputs

    homeConfigurations."benjamin@victus-15"
    homeConfigurations."benjamin@dell-latitude"

one per host that the system's `registry/hosts.nix` puts benjamin on, each made by
`system.homeLib.<host>.mkHome`.

| host | what he does there |
|---|---|
| `dell-latitude` | the daily-driver bonfire desktop (everything in `hosts/dell-latitude.nix`) |
| `victus-15` | HP Victus, headless remote builder; he has a login, no desktop (`hosts/victus-15.nix` is empty) |

`galaxybook4-pro360` is r0k0r's laptop; benjamin has no account there, so no home.

## Two repos

| repo | who writes it | what it holds |
|---|---|---|
| `github:R0K0R/nixos` (system) | the admin; users can read it | hosts, hardware, the nix daemon, accounts (`registry/`), tuning, the package set, and every system service a home depends on |
| this repo | benjamin | everything under `$HOME`: the desktop config, user services, user programs |

This repo pins **no nixpkgs and no home-manager**. Both come from the `system` input:
`homeLib.<host>.pkgs` is the host's own package set, so a home built here rebuilds nothing the system
already has. The only inputs here are programs this home alone consumes (`flake.nix` says why each
one does or does not follow a nixpkgs): `bonfire`, `sonora`, `late-sh`, `lyre`, `hearth`, `doom-private`.

The `system` input points at the `multiuser` branch, because that is the branch that exports
`homeLib`. Move it to the default branch once that is merged (`nix flake update system`).

## Layout

    flake.nix           inputs, and homeConfigurations."benjamin@<host>"
    hosts/<host>.nix    per-host choices: which modules are on
    modules/
      desktop/          hyprland (his Lua config), bonfire, flare, pyre, panelbus,
                        settings (hearth), lyre, tray applets, fcitx tray text
      editor/           neovim (NvChad seed), Emacs (his own Doom config)
      shell/            fastfetch greeting, zoxide + fzf, kitty look
      apps/             KakaoTalk (Wine), Dolphin, the package list, Storytold suite,
                        Chromium fractional-scale fix, Firefox portal preference
    packages/           orbit, opendisplay-linux
    age/authinfo.age    see "Secrets"
    SETTINGS.md         the hearth settings design
    REBRAND.md          the hakuspace -> bonfire rebrand record

Every module declares its own `options.my.<name>.enable` and does nothing until a host turns it on.
There is no NixOS half to read the switch from any more, so the home module *is* the option.
`osConfig` is read only for facts about the machine (which compositor it runs, its primary output and
scale, the Hyprland modifier), never for a switch of ours. Inside modules, `inputs` is the SYSTEM
flake's inputs (the system's feature halves need it); this repo's own inputs are `userInputs`.

The system flake's feature home halves (fish, kitty, cursor theme, qt theming, ...) are still included in
this home by `mkHome`. Where he differs from them the difference is a small module here that layers on
top (`shell/kitty.nix` overrides the kitty font and margin, `shell/fish.nix` adds zoxide and fzf);
where he does not, there is nothing here at all. `features/` holds his own copies of what the system
used to give this home: kitty, starship, eza, the cursor theme, ssh, and Doom Emacs (built from his
`doom-private` input).

## Rebuilding

    home-manager switch --flake .#benjamin@dell-latitude
    home-manager switch --flake .#benjamin@victus-15

`home-manager` is the system's CLI (the same home-manager as `homeLib`'s), installed on every host that
has a standalone account. A system switch never touches this home, and a home switch never touches the
system. `mkHome` defaults to `asSubmodule = false` for a standalone account: `home.packages` go into his own
profile, `~/.nix-profile`.

### First switch (once per host)

The system and the home move together, so do them in this order (the registry already marks his home as
`standalone`, so a system switch no longer activates it):

1. Switch the system first, so the `home-manager` CLI, the compositor (with keystone), the greeter, the
   fonts, the PAM service and the portals described below exist. Until then the home's packages are
   simply not on PATH.
2. Then activate the home. If the CLI is not there yet, use the activation package:

       nix build --no-link --print-out-paths .#homeConfigurations.'"benjamin@dell-latitude"'.activationPackage
       <that path>/activate

3. From then on, `home-manager switch` as above.

`doom-private` is a plain source input and Unstraightened (the system's) builds Doom from it with
import-from-derivation, so the first evaluation of `dell-latitude` builds Doom's package list. Run it where a
builder is reachable.

## Tuning

Your package set is a home option, set in any module here (per host in `hosts/<host>.nix` is the natural
place):

    my.tuning = { march = "system"; lto = "system"; o3 = "system"; };

`"system"` (the default) is the host's own set. `dell-latitude` is untuned (plain upstream nixpkgs, everything
from cache.nixos.org) and `victus-15` is tuned; both are fine at the default. See the system flake's
README for the levers.

## What the system must provide

Things the old flake did in a NixOS half or at host level, and a home cannot. This repo does not
duplicate them; the system flake's `dell-latitude` host has to (an `assertion` in the modules catches the
ones it can):

- **Hyprland, keystone, the session.** `my.desktop.compositor = "hyprland"`, `my.hyprland.keystone.enable = true`
  (the 3D dock and its `decoration:keystone_*` options), uwsm, the session `.desktop`, `my.desktop.primaryOutput`
  `= "eDP-1"` and `primaryOutputScale = "0.8"`.
- **The system's own Hyprland home half must not apply to benjamin.** It is applied to every account on a
  Hyprland host and writes a second, different Lua config and `hl.config` settings that would merge into (and
  conflict with) `modules/desktop/hyprland`. The same goes for `qt-theming`, which should only repair DMS's
  matugen output (his old copy was gated on `my.dms.enable`; he does not run DMS).
- **Greeter and boot.** `tuigreet` and the bonfire plymouth theme.
- **PAM.** `security.pam.services.hyprlock = { };` (`bonfire` locks with hyprlock; without a service of its
  own it falls back to `su`'s stack, which is slow and spawns `xauth`).
- **Portals and session plumbing.** The KDE `FileChooser` routing, polkit (with the pkexec wrapper), dconf and
  the compiled GSettings schemas (the system's `session-services`).
- **Fonts and locale.** Departure Mono system-wide, the `ko_KR.UTF-8` locale and the Korean fonts for
  KakaoTalk, and the `/etc/hosts` ad blackhole for its banners.
- **Emacs font.** `my.emacs.font = { family = "DepartureMono Nerd Font"; size = 16; }`: it is a system option
  that the Emacs home half turns into `doom-machine-local.el`.
- **Services and udev.** keyd (`capsHangul` + the Topre per-device map), thermald, fwupd, zram, usbmuxd and avahi
  (opendisplay), `intel-media-driver`, OpenTabletDriver, Steam, the Brother DCP-T536DW printer and `brscan5`,
  the keyboard backlight rule, syncthing, tailscale, NetworkManager, blueman (behind the tray applets), pipewire
  (behind lyre), flatpak, waydroid, firefox, fcitx5.
- **Packages the system installs for him that he replaced.** The system's `media` set installs kdenlive (he
  uses FilmCraft from `modules/apps/storytold.nix`).
- **Claude Desktop's flag.** `modules/apps/fractional-scale.nix` adds `--disable-features=WaylandFractionalScaleV1`
  from outside (a shim and a user `.desktop` entry); an option on the system's claude-desktop package for extra
  flags would replace that.

## Secrets

`age/authinfo.age` (the Doom auth-source file) is encrypted to galaxybook's key only, so it cannot be decrypted
on `dell-latitude`. It is kept for re-encryption and nothing here reads it. A user secret store like r0k0r's
`secrets/` is not set up here; the account password is a system secret because the system creates the account.

## Verification

Evaluation only, with builds disabled (`--option builders '' --option max-jobs 0 --option substituters
https://cache.nixos.org`), against the system flake's working tree:

    nix eval --raw .#homeConfigurations.'"benjamin@victus-15"'.activationPackage.drvPath \
      --override-input system git+file:///path/to/the/system/checkout
