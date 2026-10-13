# hearth settings fragment for the notification centre (features/notifcenter/shell.qml).
# Flat records keyed by dotted path; assembled into schema.json by features/settings. These are the
# first migration targets -- the panel will read them live from settings.json (Phase 2b). Add a knob
# here and it appears in the settings TUI automatically; no UI code needed.
{
  "panel.width" = {
    type = "int";
    default = 800;
    label = "Panel width";
    help = "Width of the notification-centre panel.";
    tier = "common";
    scope = "runtime";
    reload = "panel";
    constraints = { min = 480; max = 1200; step = 10; unit = "px"; };
  };

  "panel.colors.tile" = {
    type = "color";
    default = "#16ffffff";
    label = "Inactive tile";
    help = "Background wash behind an un-pressed control tile.";
    tier = "common";
    scope = "runtime";
    reload = "panel";
    constraints.alpha = true;
  };

  "panel.colors.tile_hover" = {
    type = "color";
    default = "#24ffffff";
    label = "Tile (hover)";
    help = "Control-tile background on hover.";
    tier = "common";
    scope = "runtime";
    reload = "panel";
    constraints.alpha = true;
  };

  "panel.font.family" = {
    type = "font";
    default = "DepartureMono Nerd Font";
    label = "Panel font";
    help = "Font family used throughout the notification centre.";
    tier = "common";
    scope = "runtime";
    reload = "panel";
  };

  "panel.weather.interval_min" = {
    type = "int";
    default = 20;
    label = "Weather refresh";
    help = "Minutes between weather updates.";
    tier = "advanced";
    scope = "runtime";
    reload = "panel";
    constraints = { min = 1; max = 180; unit = "min"; };
  };
}
