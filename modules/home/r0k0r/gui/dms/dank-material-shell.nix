{ lib, ... }:

let
  dmsDefaultMainBar = import ./bar-spec.nix;
in
{
  programs.dank-material-shell = {
    enable = true;

    settings = {
      theme = "dark";
      dynamicTheming = true;
      currentThemeName = "monochrome";
      niriLayoutRadiusOverride = 16;
      cursorSettings = {
        size = 12;
        theme = "Adwaita";
        niri = {
          hideWhenTyping = false;
        };
      };
      monoFontFamily = "JetBrainsMono Nerd Font Mono";
      showWorkspaceIndex = true;
      showWorkspacePadding = true;
      showWorkspaceApps = true;
      maxWorkspaceIcons = 1;
      barConfigs = [
        (lib.recursiveUpdate dmsDefaultMainBar {
          rightWidgets = dmsDefaultMainBar.rightWidgets ++ [
            {
              id = "dankKDEConnect";
              enabled = true;
            }
          ];
        })
      ];
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

    plugins = {
      dankKDEConnect.enable = true;
    };
  };
}
