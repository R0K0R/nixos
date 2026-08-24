# hop

[HOP (Open HWP)](https://github.com/golbin/hop) — a desktop editor for HWP and
HWPX, the native formats of Hancom's Korean word processor. Repackaged from
upstream's release `.deb`.

```nix
my.hop.enable = true;
```

Giftable: one external input (the `.deb`, pinned in this directory's own
`flake.lock`) and no dependency on any sibling feature. `rm -r features/hop`
takes the pin with it.

## Options

| option | default | |
|---|---|---|
| `my.hop.enable` | `false` | install HOP |
| `my.hop.defaultHandler` | `true` | make it the default app for `.hwp` / `.hwpx` |

`defaultHandler` is separate because this repo also installs LibreOffice, which
claims `application/x-hwp` through its own desktop entry and imports HWP with
different fidelity. Trying HOP and handing it every `.hwp` on the machine are
two decisions; without the split, which one won would come down to mimeapps
list order.

## What this packaging actually does

HOP is **Tauri v2, not Electron** — the README upstream says Electron, and for
the Linux target that is wrong. The payload is one 53 MB ELF linked against the
*system* WebKitGTK (`libwebkit2gtk-4.1`, `libjavascriptcoregtk-4.1`,
`libsoup-3`, `gtk-3`), plus a desktop entry and four PNGs. That is why this is a
`dpkg`-extract job and not a source build: HOP is a pnpm monorepo bundled by
`tauri-bundler`, so building it needs the pnpm store and network fetches inside
the sandbox to produce a binary already published as a release asset.

Two upstream bugs are fixed here, both Linux-only, both consistent with a
bundler validated on macOS — where file association goes through the app
bundle's `Info.plist` and never touches a `.desktop` file:

1. **`Exec=hop-desktop` carries no field code.** A file manager opening a
   document by association passes the path nowhere, and you get an empty window.
   The binary *does* consume `argv` — it links `tauri-plugin-single-instance`
   2.4.1, whose Linux implementation forwards `argv` over D-Bus to the running
   instance, which is exactly the open-this-file path. So the fix is `%F`, not a
   patched binary.

2. **`.hwpx` is not a known MIME type.** shared-mime-info 2.4 defines
   `application/x-hwp` (glob `*.hwp`, alias `application/vnd.haansoft-hwp`) and
   nothing at all for hwpx, so a real `.hwpx` resolves to `application/zip` and
   the desktop entry's `MimeType=application/vnd.hancom.hwpx` named a type no
   glob could produce. `hwpx-mime.xml` supplies the missing definition.

`autoPatchelfHook` rather than a manual `patchelf` loop: there is one
well-behaved ELF, so the build can *fail* on an unresolved library instead of
deferring it to a runtime crash. `wrapGAppsHook3` rather than hand-rolled
`makeWrapper`, because this is a real GTK3 app and wants the standard GTK
runtime environment.

## Known warts

**The in-app updater cannot work here.** HOP ships Tauri's updater and checks
`latest.json` on every launch; its `linux-x86_64-deb` target would download a
`.deb` and try to install it, which does nothing useful on NixOS. Bump the
pinned tag and rebuild instead. Harmless while pinned and current — the check
just finds the version it already is.

**`GStreamer element appsink not found`** on every launch. WebKitGTK wants
GStreamer for HTML5 media inside the webview; a document editor does not reach
that path. See the comment in `package.nix` for the remedy and its cost.

## Updating

Edit the tag in `hop-src` and relock:

```sh
# features/hop/flake.nix:  url = "github:golbin/hop/v0.5.0";
nix flake update --flake ./features/hop
nix flake update feat-hop            # from the repo root
```

There is no `update.sh` any more, and the reason is worth recording. It existed
because the old `.deb` pin stated the version *twice* — inside the release URL
and again as an exported attr — so something had to rewrite both in lockstep or
they would drift. A git input carries `package.json`, so `version` is read from
the source and cannot disagree with the pin. Bumping is one tag edit.

Both locks still need updating, because a `path:` input carries no narHash: the
root keeps serving the old revision until `nix flake update feat-hop` runs, and
the change never reaches a host.

`nix flake update` alone will not move you to a new release — `hop-src` is
pinned to a *tag*, and tags do not move. That is deliberate: tracking a branch
would let an upstream push change a build with no diff in this repo. Pointing
`hop-src` at a branch is a one-word change if you ever want the opposite.

`rhwp-src` points at our fork rather than `edwardkim/rhwp`; see the comment in
`flake.nix` for why, and for why that forces a source build rather than a `.deb`
repack. Bumping HOP without rebasing that branch onto the matching rhwp revision
will build HOP against the wrong core.

The `.desktop` rewrite uses `--replace-fail`, so if upstream renames the `Exec`
line the build fails loudly rather than shipping a broken association.
