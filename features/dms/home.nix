{ config, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.dms.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "dms"; };
in
let
  aiOllamaHost = "yulee";
  /* Must match `ollama list`; adjust if yours differs e.g. `gemma3:27b`. */
  aiOllamaModel = "gemma4-31b";
in
{
  /*
    Feature-private helpers. `imports` cannot be gated, so these are always
    imported and each gates its own config on osConfig.my.dms.enable.
    third-party.nix pulls in the upstream DMS home modules -- it belongs to this
    feature rather than to a global "third-party imports" file, so that deleting
    features/dms/ takes its whole dependency surface with it.
  */
  imports = [
    ./third-party.nix
    ./session-lock-hooks.nix
    ./plugins.nix
  ];

  config = lib.mkIf (osConfig.my.dms.enable && inScope) {
  programs.dank-material-shell = {
    enable = true;

    /*
      The full DMS config lives in ./settings.nix as a plain Nix attrset --
      every knob is a visible placeholder; edit there and rebuild.

      Three layers, in order of preference:

        1. settings.nix          the shared baseline
        2. derived               values the host already declares elsewhere, so
                                 a clone is correct with no host-file line
        3. my.dms.settingsOverride   per-host escape hatch for the rest

      Layer 2 exists because settings.nix was duplicating facts rather than
      expressing preferences. `enableFprint = true` was hardcoded while the host
      separately declared `services.fprintd.enable` -- so a laptop with no
      fingerprint reader would have shown a fingerprint prompt in the greeter
      that could never succeed. Reading the host's own declaration makes that
      impossible to get wrong.
    */
    settings =
      let
        derived = import ./settings.nix // {
          enableFprint = osConfig.services.fprintd.enable;
          greeterEnableFprint = osConfig.services.fprintd.enable;
        };
        ov = osConfig.my.dms.settingsOverride;
      in
      # A function gets the derived set and returns the final one -- the escape
      # hatch for list surgery, which recursiveUpdate cannot express.
      if builtins.isFunction ov then ov derived else lib.recursiveUpdate derived ov;

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
      # systemd already starts `dms`; spawn-at-startup would run a second copy (duplicate bar).
      enableSpawn = false;
      /*
        Single source of truth for keybinds lives in features/niri/home.nix and features/hyprland/home.nix
        (DMS has no hyprland equivalent of this module, so keeping bindings there is the only
        thing that works for both compositors). DMS's own IPC toggle binds (notifications,
        clipboard, notepad, powermenu, lock, night-mode, audio/brightness, process-list) are
        replicated by hand in those files instead of injected here.
      */
      enableKeybinds = false;
      includes.enable = false;
    };

    plugins = {
      dankKDEConnect.enable = true;
      aiAssistant = {
        enable = true;
        settings = {
          provider = "custom";
          baseUrl = "http://${aiOllamaHost}:8002/v1";
          model = aiOllamaModel;
          saveApiKey = false;
        };
      };
    };
  };
  };
}
