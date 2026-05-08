{ config, pkgs, inputs, ... }:

{

  imports = [
    inputs.dms.homeModules.dank-material-shell
    inputs.dms.homeModules.niri
    # niri-flake: NixOS module injects home-manager sharedModules (config); do not import homeModules.niri here.
  ];

  home.username = "r0k0r";
  home.homeDirectory = "/home/r0k0r";

  # Home Manager compatibility version (see HM `modules/misc/version.nix`).
  home.stateVersion = "26.05";

  programs.dank-material-shell = {
    enable = true;

    settings = {
      theme = "dark";
      dynamicTheming = true;
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
      enableKeybinds = true;
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
      shell_integration = "enabled";

      scrollback_lines = 50000;
      scrollback_pager = "less --chop-long-lines --RAW-CONTROL-CHARS +INPUT_LINE_NUMBER";
      enable_audio_bell = false;

      copy_on_select = "clipboard";

      strip_trailing_spaces = "smart";
      detect_urls = "yes";

      foreground = "#cdd6f4";
      background = "#1e1e2e";

      tab_bar_style = "powerline";
      tab_powerline_style = "slanted";
      tab_activity_symbol = " ";

      mouse_hide_wait = "1.5";
      focus_follows_mouse = "yes";
    };

    extraConfig = ''
      modify_font underline_position 125%
      modify_font underline_thickness 175%

      clipboard_control write-clipboard read-clipboard write-primary read-primary

      map ctrl+equal      change_font_size all +1.0
      map ctrl+minus      change_font_size all -1.0
      map ctrl+0          change_font_size all 0

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
