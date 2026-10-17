{ config, lib, pkgs, userInputs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
in
{
  options.my.userPackages.enable = lib.mkEnableOption ''
    this user's own packages: the one-off list that used to be the host's
    `my.packages.extra.user` (okular, btop, orbit, opendisplay, linecast, sonora, late.sh, the
    modern-CLI set, ...) plus the Rust toolchain from the dev-toolchain feature. These install
    into the home profile, which comes before the system's per-user profile in PATH, so a name
    present in both resolves here
  '';

  config = lib.mkIf config.my.userPackages.enable {
    home.packages = with pkgs; [
      kdePackages.okular
      btop # bonfire's theme pipeline already writes ~/.config/btop themes
      # gimp REMOVED 2026-10-10 -> replaced by PhotoCraft (flatpak ai.storyteller.photocraft, installed
      # --user from the unofficial `artcraft` (FlatPark) remote; see the craft-suite memory). `gimp` to revert.
      qalculate-qt # calculator (Qt build -- themes via qt6ct like the KDE apps)
      lunar-client # Minecraft client/launcher
      # discord lives in ./fractional-scale.nix, wrapped there with
      # --disable-features=WaylandFractionalScaleV1 for the 0.8 fractional-scale fix. A bare
      # `discord` here shadowed that wrapper in PATH, so the fix never applied -- removed;
      # that module is the single source.

      # orbit: Benjamin's own terminal music player, built from source. Packaged
      # (not `cargo install`ed) because this host has no nix-ld, so a cargo binary
      # linking libasound/libdbus would build but fail to RUN; buildRustPackage
      # embeds the rpath. See packages/orbit/package.nix -- bump rev/hash + Cargo.lock
      # there to update.
      (callPackage ../../packages/orbit/package.nix { })

      # opendisplay-linux (tixwho fork): use an iPhone/iPad as an extra Wayland display.
      # Linux sender (PipeWire + portal capture -> H.264 -> iOS receiver). See
      # packages/opendisplay.nix. RUNTIME also needs services.avahi (Wi-Fi) and/or
      # services.usbmuxd (USB) + the Hyprland screencast portal (already present).
      (callPackage ../../packages/opendisplay.nix { })

      # linecast (ashuttl/linecast): terminal weather/tides/sun/moon/radar.
      # Not in nixpkgs; packaged straight from PyPI. Pure Python, hatchling
      # build, and NO runtime deps on Linux (its only deps are win32-gated), so
      # a bare buildPythonApplication is the whole story.
      (python3.pkgs.buildPythonApplication rec {
        pname = "linecast";
        version = "2.4.0";
        pyproject = true;
        src = python3.pkgs.fetchPypi {
          inherit pname version;
          hash = "sha256-TH4elNMit617YssDriVxVowHNUgc3PJGO6vuAP5CYTw=";
        };
        build-system = [ python3.pkgs.hatchling ];
        nativeBuildInputs = [ makeWrapper ];
        pythonImportsCheck = [ "linecast" ];
        meta.mainProgram = "linecast";
        # linecast ships short aliases (weather, moon, tides, ...) that just
        # dispatch to `linecast <name>`. Upstream's `linecast link` creates them
        # as symlinks NEXT TO the binary -- which is the read-only Nix store, so
        # it errors. Bake them as wrappers here instead; each is on PATH and
        # runs the matching command.
        postInstall = ''
          for a in weather sunshine moon sky tides radar maps; do
            makeWrapper $out/bin/linecast $out/bin/$a --add-flags "$a"
          done
        '';
      })

      # Nix workflow. nh wraps nixos-rebuild with a change diff; nom turns the
      # build wall-of-text into a live tree; comma (`, foo`) runs a program
      # from nixpkgs without installing it.
      nh
      nix-output-monitor
      comma

      # Modern CLI. fzf and zoxide get their fish hooks in modules/shell/fish.nix;
      # the rest are drop-in binaries. ripgrep is already on PATH via
      # modules/editor/neovim.nix, so it is not repeated here.
      fd
      bat
      dust
      duf
      procs
      sd
      tealdeer # `tldr`; run `tldr --update` once to fetch the page cache
      hyperfine
      jless
      yq-go
      lazygit
      uv # fast Python package/project manager (Astral)
      bluetui # Bluetooth TUI; the waybar bluetooth icon opens it, also on PATH
      gping # ping with a live latency graph (`gping <host>`, multi-host too)

      # Handwritten-notes apps for the Wacom pen display (GoodNotes has no Linux
      # build -- Apple/Windows only, and its Windows app is UWP so Wine can't run
      # it). These are the GoodNotes-class Linux apps: rnote = modern infinite
      # canvas; xournalpp = mature notebooks + strong PDF annotation. Both want
      # pen PRESSURE, which needs OpenTabletDriver in Artist Mode (the OSK-tap
      # trade-off from the wacom setup notes).
      rnote
      xournalpp
      wvkbd # on-screen keyboard (wvkbd-mobintl); SUPER+O toggles it, see modules/desktop/hyprland

      # Sonora, from its flake (prebuilt packages.default; no nixpkgs follows, so the author's
      # binary cache applies).
      userInputs.sonora.packages.${system}.default

      # usbtree (gnomeria/usbtree): live USB device-tree TUI (Rust, no root/libusb). Straight from
      # nixpkgs -- it's packaged there (0.1.1), so no in-flake build needed.
      usbtree

      # late.sh CLI (mpiorowski/late-sh): the `late` companion CLI (local audio) for the SSH social
      # app. From its OWN flake (builds from source -> rpath-correct), not the prebuilt installer
      # binary, which fails to run here with no nix-ld -- and which also only patched bash_profile,
      # so fish never saw it.
      userInputs.late-sh.packages.${system}.late

      /*
        Display management (zoom/scale, placement, resolution, extend). Both
        show up in the launcher via their .desktop entries.

          wdisplays  the workhorse: applies changes LIVE through the
                     wlr-output-management Wayland protocol, which Hyprland
                     implements natively -- so it works regardless of this
                     host's Lua config (nwg-displays, by contrast, persists by
                     writing hyprlang `monitor=` lines that a Lua config cannot
                     `source`). Drag to arrange, set mode/scale/rotation,
                     enable/disable -- effective immediately.
          wlr-randr  the CLI behind it; also what a mirror toggle would script
                     (`wlr-randr --output HDMI-A-1 --pos 0,0` etc.).

        Live-only, on purpose: the built-in panel stays declarative
        (my.desktop.primaryOutput/Scale); externals are ad-hoc, re-arranged
        when plugged in. Mirroring is the one thing wdisplays can't do from its
        UI -- ask and I'll add a bound `hyprctl keyword monitor …,mirror,eDP-1`
        toggle once there's an external to test against.
      */
      wdisplays
      wlr-randr

      cava # standalone terminal audio visualizer (bonfire bundles its own
      # wrapped copy for the bar underbar; this puts `cava` on PATH too)

      # Rust: cargo + rustc (cargo can't compile without the toolchain), rust-analyzer the
      # LSP (matching clangd/basedpyright in the system's dev-toolchain). clippy/rustfmt are a
      # line away if wanted.
      cargo
      rustc
      rust-analyzer
    ];
  };
}
