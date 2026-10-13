# hearth settings fragment for the notification centre (features/flare/shell.qml).
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

  "panel.colors.background" = {
    type = "color";
    default = "#e6000000";
    label = "Panel background";
    help = "Fill behind the whole panel; the compositor blur rule frosts the desktop behind it.";
    tier = "common";
    scope = "runtime";
    reload = "panel";
    constraints.alpha = true;
  };

  "panel.colors.dim" = {
    type = "color";
    default = "#80ffffff";
    label = "Secondary text";
    help = "Dimmed/secondary text and inactive glyphs.";
    tier = "advanced";
    scope = "runtime";
    reload = "panel";
    constraints.alpha = true;
  };

  "panel.radius.tile" = {
    type = "int";
    default = 14;
    label = "Tile radius";
    help = "Corner rounding on the control-grid tiles.";
    tier = "common";
    scope = "runtime";
    reload = "panel";
    constraints = { min = 0; max = 32; unit = "px"; };
  };

  "panel.radius.card" = {
    type = "int";
    default = 20;
    label = "Panel radius";
    help = "Corner rounding of the whole panel card.";
    tier = "advanced";
    scope = "runtime";
    reload = "panel";
    constraints = { min = 0; max = 40; unit = "px"; };
  };

  "panel.radius.notification" = {
    type = "int";
    default = 16;
    label = "Notification radius";
    help = "Corner rounding on notification toast cards.";
    tier = "advanced";
    scope = "runtime";
    reload = "panel";
    constraints = { min = 0; max = 32; unit = "px"; };
  };

  "panel.clock.time_format" = {
    type = "enum";
    default = "HH:mm";
    label = "Clock format";
    help = "Time format for the panel clock (Qt date-time tokens).";
    tier = "common";
    scope = "runtime";
    reload = "panel";
    constraints.options = [ "HH:mm" "h:mm AP" "HH:mm:ss" ];
  };

  "panel.clock.date_format" = {
    type = "enum";
    default = "dddd, MMMM d";
    label = "Date format";
    help = "Date line under the clock (Qt date-time tokens).";
    tier = "advanced";
    scope = "runtime";
    reload = "panel";
    constraints.options = [ "dddd, MMMM d" "ddd d MMM" "MMMM d" "yyyy-MM-dd" ];
  };

  "panel.clock.size" = {
    type = "int";
    default = 58;
    label = "Clock size";
    help = "Point size of the large panel clock.";
    tier = "advanced";
    scope = "runtime";
    reload = "panel";
    constraints = { min = 24; max = 96; unit = "px"; };
  };
}
