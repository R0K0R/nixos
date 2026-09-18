{ config, lib, osConfig, pkgs, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.dms.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "dms"; };
in
let
  aiOllamaHost = "yulee";
  /* Must match `ollama list`; adjust if yours differs e.g. `gemma3:27b`. */
  aiOllamaModel = "gemma4-31b";

  # Hoisted out of `settings` below so the weather-pin activation can read the
  # SAME final values. Deriving the pin from anything else would let the two
  # drift, which is the failure this whole thing is cleaning up after.
  dmsSettings =
    let
      derived = import ./settings.nix // {
        enableFprint = osConfig.services.fprintd.enable;
        greeterEnableFprint = osConfig.services.fprintd.enable;
      };
      ov = osConfig.my.dms.settingsOverride;
    in
    if builtins.isFunction ov then ov derived else lib.recursiveUpdate derived ov;

  weatherPinJson = (pkgs.formats.json { }).generate "dms-weather-pin.json" {
    inherit (dmsSettings) weatherLocation weatherCoordinates;
  };
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
    # Keybinds, layer rules and the bar-orientation unit that used to live in
    # features/hyprland and features/niri. Contributed to whichever compositor
    # is selected, so the compositor features no longer name this shell.
    ./compositor.nix
  ];

  config = lib.mkIf (osConfig.my.dms.enable && inScope) {
  /*
    Pin the weather location into session.json.

    settings.nix can only seed these two keys on a FRESH profile: SessionData
    keeps them, and settings.json reaches them solely through
    SessionStore.migrateToVersion's `currentVersion < 2` branch, which never
    runs again once a session has migrated (see the comment in settings.nix).
    So on any existing profile the declared value is inert and DMS falls back
    to its built-in New York default -- which is what happened here.

    Merged rather than symlinked, for the same reason as claude-desktop's MCP
    config: DMS owns this file and rewrites it whenever session state changes,
    so it cannot be a read-only store path. Idempotent -- a switch that
    changes nothing leaves the file's mtime alone.

    Only when the file ALREADY EXISTS. Absent means a fresh profile, where
    DMS's own migration does the right thing from settings.json; creating one
    here would just race that.

    Skipped entirely when useAutoLocation is on, so turning auto-location back
    on in settings.nix is sufficient and does not also require deleting this.

    Note v4 stripDefaults: session.json stores only keys that DIFFER from the
    spec default, so these two being absent from it is normal.
  */
  home.activation.dmsWeatherPin =
    lib.mkIf (!(dmsSettings.useAutoLocation or false))
      (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        session="''${XDG_STATE_HOME:-$HOME/.local/state}/DankMaterialShell/session.json"
        if [ -f "$session" ]; then
          # `|| true` so a hand-corrupted session.json fails this step shut
          # instead of truncating the file.
          merged="$(${pkgs.jq}/bin/jq --slurpfile pin ${weatherPinJson} \
            '. + $pin[0]' "$session" 2>/dev/null || true)"
          if [ -n "$merged" ] && [ "$merged" != "$(cat "$session")" ]; then
            run printf '%s\n' "$merged" > "$session"
          fi
        fi
      '');
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
    # Assembled in the top-level `let` as dmsSettings. A function override gets
    # the derived set and returns the final one -- the escape hatch for list
    # surgery, which recursiveUpdate cannot express.
    settings = dmsSettings;

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
