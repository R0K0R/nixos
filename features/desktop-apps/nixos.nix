{ config, lib, pkgs, ... }:

let
  cfg = config.my.desktop-apps;

  /*
    Read here rather than assembled centrally, so this feature installs its own
    packages for anyone who drops the directory into a config that has never
    heard of this repo's conventions. tuning/runtime-cache/lookup.nix reads the
    same file independently for its Tier 3 anchor set -- two consumers, one
    file, no coupling between them.
  */
  pkgSet = import ./packages.nix { inherit pkgs; };
in
{
  options.my.desktop-apps.enable = lib.mkEnableOption "GUI applications and the icon/theme packages they resolve against";

  # Accounts this feature applies to; defaults to the primary user.
  options.my.desktop-apps.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      /*
        rnote SIGSEGV on touch: when the canvas's two-finger pan claims a touch
        sequence, GTK cancels the pinch-zoom gesture on it and emits `cancel`
        WHILE denying the sequence. rnote 0.14.2's handler then calls
        set_state(Denied) itself, re-entering GTK's state propagation for a
        sequence being torn down; gdk_event_get_event_type reads a dangling
        event. Coredump 2026-09-26 (frames: scrolled_window_drag_update_cb ->
        _gtk_gesture_cancel_sequence -> rnote GestureZoom cancel ->
        gtk_gesture_set_state -> gdk_event_get_event_type). Same crash site as
        upstream flxzt/rnote#1848 (open, unfixed in 0.14.2). Drop when fixed.
      */
      nixpkgs.overlays = [
        (final: prev: {
          rnote = prev.rnote.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              ./rnote-zoom-cancel-reentrancy.patch
              # Deep zoom on imported PDF pages: render only the visible part once a
              # full-page image would pass 16 Mpx, instead of a whole-page bitmap that
              # grows with zoom^2. Built against stock 0.14.2 on yulee 2026-10-05.
              ./rnote-vectorimage-viewport-clip.patch
            ];

            /*
              Memory, measured 2026-10-05 on a document with imported PDF pages:
              rnote idled at 2.5 GB, of which ~1.2 GB was freed memory kept in
              glibc's per-thread arenas (64/128 MB regions, one per render
              thread), and pinch-zooming spiked it to 5 GB+ -- once to ~34 GB and
              an OOM kill that froze the laptop for minutes. Cause: imported PDF
              pages (VectorImage) render as a FULL-page bitmap at the current
              zoom, so memory grows with zoom^2 (a 981 MB solid-white page buffer
              was found live).

              MALLOC_ARENA_MAX=2 caps the arenas, returning most of the retained
              memory. --set-default, so an explicit value still wins.
            */
            preFixup = (old.preFixup or "") + ''
              gappsWrapperArgs+=(--set-default MALLOC_ARENA_MAX 2)
            '';

            /*
              ...and a cap, so a runaway render dies on its own in seconds
              instead of dragging the whole system through swap. The desktop
              entry runs `rnote`, so `rnote` becomes a launcher that starts the
              real one in its own scope. MemoryHigh makes the kernel reclaim
              hard first; past MemoryMax only rnote is killed. Swap is limited
              too, since a scope allowed to swap freely just moves the freeze.
              Falls back to a plain exec where systemd-run cannot work.
            */
            postFixup = (old.postFixup or "") + ''
              mv "$out/bin/rnote" "$out/bin/.rnote-uncapped"
              cat > "$out/bin/rnote" <<EOF
              #!${final.runtimeShell}
              if command -v systemd-run >/dev/null 2>&1 && [ -n "\''${DBUS_SESSION_BUS_ADDRESS:-}\''${XDG_RUNTIME_DIR:-}" ]; then
                exec systemd-run --user --scope --collect --quiet \\
                  -p MemoryHigh=5G -p MemoryMax=7G -p MemorySwapMax=1G \\
                  -- "$out/bin/.rnote-uncapped" "\$@"
              fi
              exec "$out/bin/.rnote-uncapped" "\$@"
              EOF
              chmod +x "$out/bin/rnote"
            '';
          });
        })
      ];
    }

    (lib.mkIf (pkgSet ? system) { environment.systemPackages = pkgSet.system; })
    # Emitted only when non-empty, and keyed by this feature's `users`
    # scope rather than by a hardcoded account -- see lib/user-scope.nix.
    (lib.mkIf (pkgSet ? user) { my.packages.perUser = lib.genAttrs config.my.desktop-apps.users (_: pkgSet.user); })

    {
      /*
        MTP: what makes a plugged-in phone actually appear in dolphin.

        kio-extras already ships the worker (lib/qt-6/plugins/kf6/kio/mtp.so,
        linked against libmtp) and dolphin's wrapper puts kio-extras on
        QT_PLUGIN_PATH, so the SOFTWARE half has been complete all along. What
        was missing is the udev half: libmtp's 69-libmtp.rules sat unused in the
        store, so a connected phone was never tagged ID_MTP_DEVICE=1 and never
        got uaccess. The device enumerated correctly -- Samsung 04e8:6860, the
        MTP product id -- and then nothing on the host claimed it, so Solid
        never offered it and dolphin showed nothing. Diagnosed 2026-09-16.

        libmtp.out, not libmtp: the rules live in $out/lib/udev/rules.d, while
        the default output for this package is `bin`.
      */
      services.udev.packages = [ pkgs.libmtp.out ];
    }
  ]);
}
