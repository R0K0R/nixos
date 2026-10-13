# hearth settings fragment for the side dock (features/pyre/dock.sh). dock.sh reads these live from
# ~/.local/state/hearth/settings.json (jq) on each dock action; the size/inset knobs default to 0 =
# "auto" so the screen-scaled default is kept until you set an explicit px. Add a knob here + a matching
# `hs` read in dock.sh.
{
  "dock.width" = {
    type = "int";
    default = 0;
    label = "Card width";
    help = "Front dock-card width in px. 0 = auto (~1/3 of the screen, clamped 420–900).";
    tier = "common";
    scope = "runtime";
    reload = "dock";
    constraints = { min = 0; max = 1000; unit = "px"; };
  };

  "dock.gap.right" = {
    type = "int";
    default = 0;
    label = "Right inset";
    help = "How far the pile sits in from the right screen edge, px. 0 = auto (~W/60).";
    tier = "common";
    scope = "runtime";
    reload = "dock";
    constraints = { min = 0; max = 200; unit = "px"; };
  };

  "dock.gap.vertical" = {
    type = "int";
    default = 0;
    label = "Vertical margin";
    help = "Top/bottom margin of the dock region, px. 0 = auto (~H/28).";
    tier = "advanced";
    scope = "runtime";
    reload = "dock";
    constraints = { min = 0; max = 200; unit = "px"; };
  };

  "dock.cascade.shrink" = {
    type = "int";
    default = 9;
    label = "Cascade shrink";
    help = "Each card behind the front shrinks by this percent of the front card.";
    tier = "common";
    scope = "runtime";
    reload = "dock";
    constraints = { min = 0; max = 30; unit = "%"; };
  };

  "dock.cascade.depth" = {
    type = "int";
    default = 3;
    label = "Cascade depth";
    help = "How many cards deep the receding stack is drawn.";
    tier = "advanced";
    scope = "runtime";
    reload = "dock";
    constraints = { min = 1; max = 8; };
  };
}
