{ config, lib, pkgs, ... }:

let
  cfg = config.my.fcitx;
in
{
  options.my.fcitx.enable =
    lib.mkEnableOption "fcitx5 input method (Hangul), Wayland-native, started as a user service";

  # Accounts this feature applies to; defaults to the primary user.
  options.my.fcitx.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable {
    /*
      THE GTK3 IMMODULES CACHE, synthesized -- because under pseudo-cross the
      tuned gtk3 ships none, and without it no GTK3 app has an IME at all.

      Measured, not inferred, on Firefox 154 and Emacs PGTK (both tuned GTK3):
      the compositor advertised zwp_text_input_manager_v3 on every registry and
      neither app ever bound it. Keystrokes arrived as raw wl_keyboard.key
      events; fcitx5 sat in Hangul mode, correctly toggled, and never saw a key.
      kitty, DMS and Claude Desktop were unaffected only because none of them
      is GTK3 -- which is why this looked like a Firefox bug for a long time.

      WHY THE CACHE MATTERS. GTK3's Wayland input-method context is NOT built
      into libgtk-3; it is a loadable module, im-wayland.so, and GTK only
      learns which .so provides which context id by reading immodules.cache.
      No cache, no "wayland" context, and every app silently falls back to
      gtk-im-context-simple. Neither GTK_IM_MODULE=wayland nor an empty cache
      helps (both tested): the module has to be LISTED.

      WHY IT IS MISSING. gtk3's postInstall generates the cache by executing
      gtk-query-immodules-3.0, guarded by `buildPlatform == hostPlatform` --
      false here, since the platforms differ by gcc.arch. i18n.inputMethod's
      enableGtk3 would regenerate it under hostPlatform.emulator, which is
      qemu-x86_64 under pseudo-cross and cannot run the tuned tool either.

      SO: TEXT SUBSTITUTION, NO EXECUTION. The cache is plain text whose only
      store path is gtk3's own `out`, and the build- and host-platform gtk3
      are the same source version with the same module set. Taking the
      untuned cache and rewriting the store path yields exactly what the
      query tool would have printed. Both facts are asserted at build time
      rather than assumed: a missing source cache or a differing module set
      fails the build with a message, instead of producing a cache that
      points at files that do not exist.

      INSTALLED THE WAY NIXOS DOES IT. nixpkgs patches gtk3 to look for
      <profile>/etc/gtk-3.0/immodules.cache across NIX_PROFILES before falling
      back to its compiled-in path (3.0-immodules.cache.patch), and /etc/gtk-3.0
      is in the default pathsToLink. A systemPackages entry is therefore
      enough -- no environment variable, and newly launched apps pick it up
      right after the switch, no re-login. It also means turning enableGtk3 on
      later collides on the same path at build time, loudly, rather than one
      cache silently shadowing the other.

      Verified live before this was written: Firefox launched with this cache
      binds the text-input manager and Hyprland stops delivering it raw keys.

      Gated on canExecute, not on enable alone: a native host's gtk3 ships its
      own cache and needs nothing from here.

      pkgsBuildBuild.runCommand, deliberately: this is sed on a text file, and
      the tuned runCommand would make it depend on the tuned bash/sed/diffutils
      -- an entire tuned stdenv chain -- for no benefit. The build-platform one
      is substitutable. The result still references the TUNED gtk3, which is
      the point; only the tools doing the rewriting are untuned.
    */
    environment.systemPackages =
      lib.optional (!(pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform)) (
        pkgs.pkgsBuildBuild.runCommand "gtk3-immodules.cache"
          {
            untuned = pkgs.pkgsBuildBuild.gtk3.out;
            tuned = pkgs.gtk3.out;
            preferLocalBuild = true;
            allowSubstitutes = false;
          }
          ''
            u="$untuned/lib/gtk-3.0/3.0.0"
            t="$tuned/lib/gtk-3.0/3.0.0"

            if [ ! -f "$u/immodules.cache" ]; then
              echo "gtk3-immodules.cache: the build-platform gtk3 ($untuned) has no immodules.cache to substitute from" >&2
              exit 1
            fi
            if ! diff <(ls "$u/immodules") <(ls "$t/immodules"); then
              echo "gtk3-immodules.cache: build- and host-platform gtk3 ship different immodule sets; refusing to synthesize a cache that would name missing files" >&2
              exit 1
            fi

            mkdir -p "$out/etc/gtk-3.0"
            sed "s|$untuned|$tuned|g" "$u/immodules.cache" > "$out/etc/gtk-3.0/immodules.cache"

            if ! grep -q 'im-wayland\.so' "$out/etc/gtk-3.0/immodules.cache"; then
              echo "gtk3-immodules.cache: synthesized cache lists no im-wayland.so -- the whole point of this file" >&2
              exit 1
            fi
            if grep -q "$untuned" "$out/etc/gtk-3.0/immodules.cache"; then
              echo "gtk3-immodules.cache: untuned store path survived substitution" >&2
              exit 1
            fi
          ''
      );

    i18n.inputMethod = {
      enable = true;
      type = "fcitx5";
      /*
        OFF, and replaced by the synthesized cache below -- read that comment.

        enableGtk3 builds a GTK3 immodules.cache by RUNNING gtk-query-immodules-3.0
        under stdenv.hostPlatform.emulator. Under pseudo-cross that emulator
        resolves to qemu-x86_64 (nixpkgs sees an x86_64 -> x86_64 "cross" and
        offers qemu-user for it), and TCG does not implement the meteorlake
        instructions the tuned tool is compiled with. That is the "fails in
        cross builds" this used to be blamed on.

        The claim that used to sit here -- "the Wayland input-method protocol
        makes the cache unnecessary" -- was wrong, and cost every GTK3 app its
        IME. See below.
      */
      enableGtk3 = false;
      fcitx5 = {
        waylandFrontend = true;
        addons =
          (
            with pkgs; [
              /* OnDemand hangul means the IME never registers until explicitly loaded —
                 fcitx then drops it from ~/.config/profile, so Alt_R has nothing to switch to.
                 Disable on-demand loading so Hangul joins the IME list at startup. */
              (fcitx5-hangul.overrideAttrs (old: {
                postInstall =
                  (old.postInstall or "")
                  + ''
                    substituteInPlace $out/share/fcitx5/addon/hangul.conf --replace-fail 'OnDemand=True' 'OnDemand=False'
                  '';
              }))
              fcitx5-gtk
            ]
          )
          ++ [
            pkgs.kdePackages.fcitx5-qt
          ];

        /*
          Global options + IME profile live in this feature's home.nix
          (~/.config/fcitx5/{config,profile}) so the user dir is the single
          source of truth instead of merging /etc vs ~/.config.
        */
      };
    };

    /* Niri pulls in xdg-desktop-autostart very early; fcitx5 often never stays up via the
       .desktop entry alone. Start it as a user service after graphical-session.target instead. */
    systemd.user.services.fcitx5-daemon = lib.mkIf (
      config.i18n.inputMethod.enable && config.i18n.inputMethod.type == "fcitx5"
    ) {
      description = "Fcitx 5 input method";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${config.i18n.inputMethod.package}/bin/fcitx5";
        Slice = "session.slice";
        Restart = "always";
        RestartSec = 5;
      };
      wantedBy = [ "graphical-session.target" ];
    };
  };
}
