{ config, pkgs, inputs, lib, ... }:

let

  dms-plugin-registry = {
    url = "github:AvengeMedia/dms-plugin-registry";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  /* Pin from flake input `nixpkgs-emacs-webkit` — use `.legacyPackages` here, not `import … { config = pkgs.config }`,
     or NixOS’s nixpkgs options leak into 22.11 and blow up (`replaceStdenv` / stdenv mismatch). */
  pkgsWebkit = inputs.nixpkgs-emacs-webkit.legacyPackages.${pkgs.system};

  /* Unstable `emacs-pgtk` (e.g. 30.x) + xwidgets, but linked against the older WebKit above. */
  emacsPgtkBase =
    (pkgs.emacs-pgtk.override {
      webkitgtk_4_1 = pkgsWebkit.webkitgtk_4_1;
      withNativeCompilation = true;
      withTreeSitter = true;
      withSystemd = true;
      withXwidgets = true;
    });

  /* `pkgs.libvterm` is not the Neovim libvterm API emacs-libvterm expects. nixpkgs’ `emacsPackagesFor … .vterm`
     builds against `libvterm-neovim` with the same Emacs we run; we copy `vterm-module.so` into Straight’s
     emacs-libvterm checkout on home activation (see `installNixEmacsVtermIntoStraight`). */
  emacsVtermModulePkg = (pkgs.emacsPackagesFor emacsPgtkBase).vterm;

  emacsRolling = emacsPgtkBase;

  /* Kitty kittens from https://github.com/end-4/dots-hyprland (dots/.config/kitty/). */
  kittySearchPy = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/end-4/dots-hyprland/main/dots/.config/kitty/search.py";
    /* nix-prefetch-url output (base32); do not prefix with sha256- here */
    sha256 = "15z1cs4wwxnvw96hkj7zl5wy7a26q8qnvc812vph93mnz9q2qsvq";
  };
  kittyScrollMarkPy = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/end-4/dots-hyprland/main/dots/.config/kitty/scroll_mark.py";
    sha256 = "1a1l7sp2x247da8fr54wwq7ffm987wjal9nw2f38q956v3cfknzi";
  };

  fcitx5Ini = lib.generators.toINI { };

  fcitx5Cfg = {
    /* TriggerKeys: full IME inactive/active; Hangul deliberately omitted (physical RAlt → Hangul via keyd). */
    "Hotkey/TriggerKeys" = {
      "0" = "Control+space";
      "1" = "Zenkaku_Hankaku";
    };
    /*
      Physical Hangul/Eisu emitted by keyd (`hangeul`); must not collide with Hangul inside TriggerKeys
      unless you accept double-hotkey semantics.
    */
    "Hotkey/EnumerateForwardKeys" = {
      "0" = "Hangul";
    };
    "Behavior".ActiveByDefault = true;
  };

  fcitx5Prof = {
    "Groups/0" = {
      Name = "Default";
      "Default Layout" = "us";
      DefaultIM = "keyboard-us";
    };
    "Groups/0/Items/0" = {
      Name = "keyboard-us";
      Layout = "";
    };
    "Groups/0/Items/1" = {
      Name = "hangul";
      Layout = "";
    };
    GroupOrder."0" = "Default";
  };

in
{

  imports = [
    inputs.dms.homeModules.dank-material-shell
    inputs.dms.homeModules.niri
    # niri-flake: NixOS module injects home-manager sharedModules (config); do not import homeModules.niri here.
  ];

  /* Niri asks GTK to drop CSD (`prefer-no-csd`). That does not remove title bars on
     already-running apps — restart Emacs, not only niri. Emacs PGTK can still request
     CSD; `undecorated' is set in $DOOMDIR/init.el for that case. */

  programs.niri.settings = {
    prefer-no-csd = true;
    /* niri-flake renders only binds you list — it does not merge niri’s built-in defaults.
       Keep upstream defaults in ./niri-default-binds.nix and layer overrides here. */
    binds =
      lib.mergeAttrs (import ./niri-default-binds.nix)
        (
          with config.lib.niri.actions;
          {
            "Mod+Space" = {
              action = spawn "dms" "ipc" "spotlight" "toggle";
              hotkey-overlay.title = "Launcher";
            };

            "Mod+Return" = {
              action = spawn "kitty";
              hotkey-overlay.title = "Terminal";
            };

            "Mod+w" = {
              action = spawn "firefox";
              hotkey-overlay.title = "Browser";
            };

            /* Not Mod+c: niri folds case; Mod+C is center-column in upstream defaults. */
            "Mod+e" = {
              action = spawn "emacs";
              hotkey-overlay.title = "Editor";
            };
          }
        );
  };

  home.username = "r0k0r";
  home.homeDirectory = "/home/r0k0r";

  # Home Manager compatibility version (see HM `modules/misc/version.nix`).
  home.stateVersion = "26.05";

  /* Store-backed immutable fcitx5 config (`configuration.nix` still builds fcitx5-with-addons + patched hangul). */
  xdg.configFile."fcitx5/config" = {
    force = true;
    text = fcitx5Ini fcitx5Cfg;
  };
  xdg.configFile."fcitx5/profile" = {
    force = true;
    text = fcitx5Ini fcitx5Prof;
  };

  programs.ssh = {
    enable = true;

    matchBlocks = {
      yulee = {
        hostname = "10.8.0.22";
        user = "r0k0r";
      };
    };
  };

  home.file.".ssh/known_hosts".text = ''
      yulee,10.8.0.22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2O6gqRdfKcKJQU/KLBGSnsf1VKj67IfHqzAEyWn014
    '';


  # Doom owns Emacs startup; skipping HM avoids an emacsWithPackages wrapper injecting default.el.
  programs.emacs.enable = false;

  /* DOOMDIR → flake input `doom-private` (https://github.com/R0K0R/doom-emacs). */
  xdg.configFile."doom".source = inputs.doom-private;

  xdg.configFile."kitty/search.py".source = kittySearchPy;
  xdg.configFile."kitty/scroll_mark.py".source = kittyScrollMarkPy;

  home.packages =
    let
      doomcli = "${config.home.homeDirectory}/.emacs.d/bin/doom";
    in
    with pkgs; [
      emacsRolling
      imagemagick # PGTK Emacs cannot enable --with-imagemagick in nixpkgs; use CLI / scripts.

      /* ~/.emacs.d/bin is easy to miss in PATH (fish/kitty must source hm-session-vars). This shadows nothing: same script. */
      (writeShellScriptBin "doom" ''
        set -euo pipefail
        if ! [ -x "${doomcli}" ]; then
          echo "doom: expected executable at ${doomcli} (run home activation / nixos-rebuild first)." >&2
          exit 127
        fi
        exec "${doomcli}" "$@"
      '')

      git
      ripgrep
      fd
      findutils
      gnutar
      gzip
    ];

  home.sessionPath = [
    "${config.home.homeDirectory}/.emacs.d/bin"
  ];

  home.activation.syncDoomEmacsFramework = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    EMACSD="${config.home.homeDirectory}/.emacs.d"
    SRC="${inputs.doom-emacs}"
    mkdir -p "$EMACSD"
    # --no-{owner,group,perms}: ignore store UID and read-only modes; apply normal Unix modes + chmod below.
    ${lib.getExe pkgs.rsync} -a --delete --exclude '.local/' \
      --no-owner --no-group --no-perms \
      "$SRC/" "$EMACSD/"
    if [[ -d "$EMACSD/bin" ]]; then
      chmod -R u+rwx "$EMACSD/bin"
    fi
    find "$EMACSD" -mindepth 1 -maxdepth 1 ! -name '.local' ! -name 'bin' -exec chmod -R u+rwX {} +
  '';

  /* After Doom’s straight checkout exists: install the store-built module (libs + Emacs match).

     Straight’s native-comp/tree layout resolves `locate-library' for vterm.el to
     ~/.emacs.d/.local/straight/build-<ver>/vterm/ (symlink farm), while `emacs-libvterm' lives under
     repos/. `vterm.el' picks the build-* path for `require'/`vterm-module-compile', so the .so must
     exist beside that vterm.el, not only under repos/emacs-libvterm. */
  home.activation.installNixEmacsVtermIntoStraight = lib.hm.dag.entryAfter [ "syncDoomEmacsFramework" ] ''
    set -euo pipefail
    shopt -s nullglob
    vf=( ${emacsVtermModulePkg}/share/emacs/site-lisp/elpa/vterm-*/vterm-module.so )
    if [[ ''${#vf[@]} -eq 0 ]]; then
      echo "home-manager: no vterm-module.so under ${emacsVtermModulePkg}" >&2
      exit 0
    fi
    so="''${vf[0]}"
    straight="${config.home.homeDirectory}/.emacs.d/.local/straight"
    repo="$straight/repos/emacs-libvterm"
    if [[ -d "$repo" ]]; then
      install -Dm444 "$so" "$repo/vterm-module.so"
    fi
    if [[ -d "$straight" ]]; then
      for d in "$straight"/build-*/vterm; do
        [[ -d "$d" ]] || continue
        install -Dm444 "$so" "$d/vterm-module.so"
      done
    fi
  '';

  programs.dank-material-shell = {
    enable = true;

    settings = {
      theme = "dark";
      dynamicTheming = true;
      currentThemeName = "monochrome";
      niriLayoutRadiusOverride = 16;
      cursorSettings = {
        size = 12;
      };
      monoFontFamily = "JetBrainsMono Nerd Font Mono";
      showWorkspaceIndex = true;
      showWorkspacePadding = true;
      showWorkspaceApps = true;
      maxWorkspaceIcons = 1;
    };

    systemd = {
      enable = true;
      restartIfChanged = true;
    };

    enableSystemMonitoring = true;
    enableVPN = true;
    enableDynamicTheming = true;
    enableAudioWavelength = true;
    enableCalendarEvents = true;
    enableClipboardPaste = true;

    niri = {
      enableSpawn = true;
    };
  };

  programs.kitty = {
    enable = true;

    shellIntegration.enableFishIntegration = true;

    settings = {
      shell = "${pkgs.fish}/bin/fish";

      font_family = "JetBrainsMono Nerd Font";
      bold_font = "auto";
      italic_font = "auto";
      bold_italic_font = "auto";
      font_size = 11;

      cursor_shape = "beam";
      cursor_beam_thickness = 2;
      cursor_trail = 1;
      shell_integration = "enabled";

      /* Needed for dots-hyprland-style search kitten (launch … kitty @ …). */
      allow_remote_control = "yes";

      /* Inspired by https://github.com/end-4/dots-hyprland/blob/main/dots/.config/kitty/kitty.conf */
      window_margin_width = 21.75;
      /* Kitty ≥0.40: integer, not yes/no; HM bools become `no` and break parsing. 0 = never confirm. */
      confirm_os_window_close = 0;

      scrollback_lines = 50000;
      scrollback_pager = "less --chop-long-lines --RAW-CONTROL-CHARS +INPUT_LINE_NUMBER";
      enable_audio_bell = false;

      copy_on_select = "clipboard";

      strip_trailing_spaces = "smart";
      detect_urls = "yes";

      foreground = "#cdd6f4";
      background = "#1e1e2e";

      /*
        Gray "[> command X]" strip = Kitty’s own tab/title bar (shell integration
        updates the title). Niri does not draw that. Hide for a flat window like
        end-4’s minimal kitty.conf (no tab_bar_* there).
      */
      tab_bar_style = "hidden";

      /* Prefer niri’s SSD / no extra client titlebar when supported. */
      hide_window_decorations = true;

      mouse_hide_wait = "1.5";
      focus_follows_mouse = "yes";
    };

    extraConfig = ''
      modify_font underline_position 125%
      modify_font underline_thickness 175%

      clipboard_control write-clipboard read-clipboard write-primary read-primary

      map ctrl+c copy_or_interrupt

      map ctrl+f launch --location=hsplit --allow-remote-control kitty +kitten search.py @active-kitty-window-id
      map kitty_mod+f launch --location=hsplit --allow-remote-control kitty +kitten search.py @active-kitty-window-id

      map page_up scroll_page_up
      map page_down scroll_page_down

      map ctrl+plus change_font_size all +1
      map ctrl+equal change_font_size all +1
      map ctrl+kp_add change_font_size all +1
      map ctrl+minus change_font_size all -1
      map ctrl+underscore change_font_size all -1
      map ctrl+kp_subtract change_font_size all -1
      map ctrl+0 change_font_size all 0
      map ctrl+kp_0 change_font_size all 0

      map ctrl+shift+t     new_tab_with_cwd
      map ctrl+shift+right next_tab
      map ctrl+shift+left  previous_tab

      map ctrl+shift+u     kitten hints --type url
      map ctrl+shift+o     kitten hints --type linenum --program @
      map ctrl+shift+p     kitten hints --type path --program -

      map ctrl+shift+h     show_scrollback
    '';
  };
}
