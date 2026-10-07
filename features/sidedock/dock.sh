#!/usr/bin/env bash
# From sihooleebd/nixos (features/sidedock/dock.sh at 0a7686c); geom()'s monitor and bar
# detection replaced with the focused monitor's logical size and reserved area.
# Side dock: floating windows tagged 'dock' live on a right-edge panel as a
# CASCADE STACK. The front window sits at the panel base (full opacity + raised); the
# rest fan out behind it toward the lower-left (dimmed to ~0.62, peeking their edges).
# Opacity is per-position and multiplies each app's own alpha (glass stays glass). One
# keybind SHIFTS the pile -- the front rotates to the back and everything slides
# one step, which Hyprland animates. Hiding parks the whole pile off the right
# edge but remembers which window was in front, so the next cycle restores it.
#
# Every placement is done BY ADDRESS (move/opacity/z-order/float all take a
# `window=`), never by focusing, so main-area windows are never disturbed; only
# the front window is focused at the end, for typing.
#
# Verbs:  cycle  show the pile / shift to the next window (wraps)
#         hide   park the whole pile off-screen (remembers the front)
#         send   push the focused window into the dock
#         pull   return the front window to the main tiling area
set -uo pipefail
export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-$(ls "${XDG_RUNTIME_DIR:-/run/user/1000}/hypr/" 2>/dev/null | head -1)}"
HC=hyprctl; J=jq
STATE="${XDG_RUNTIME_DIR:-/run/user/1000}/sidedock.front"   # remembers the front across hide

geom() {
  # LOGICAL geometry of the FOCUSED monitor: window moves are in logical coordinates,
  # while `monitors` reports the mode in device pixels -- divide by scale, and swap for a
  # 90/270 rotation. Clear whatever bar is there via the monitor's reserved area
  # [left, top, right, bottom] rather than measuring one particular bar. (Local
  # adaptation; upstream picks the rightmost monitor and measures a waybar layer.)
  local t r0 r1 r2 r3
  read -r LW LH X0 Y0 r0 r1 r2 r3 t < <($HC monitors -j | $J -r '.[]|select(.focused)
    | (if (.transform % 2) == 1 then [.height, .width] else [.width, .height] end) as $wh
    | "\(($wh[0] / .scale) | floor) \(($wh[1] / .scale) | floor) \(.x) \(.y) \(.reserved[0]) \(.reserved[1]) \(.reserved[2]) \(.reserved[3]) \(.transform)"')
  [ -n "${LW:-}" ] && [ "$LW" -gt 0 ] 2>/dev/null || { LW=1920; LH=1080; X0=0; Y0=0; r0=0; r1=0; r2=0; r3=0; t=0; }   # fallback

  # THE DOCK STAYS ON THE SAME PHYSICAL EDGE: the panel's own right edge, wherever a
  # rotation puts it. wl_output transform 90 turns content counter-clockwise, so that edge
  # is logical right at 0, BOTTOM at 90 (a wide trapezoid along the bottom), left at 180,
  # top at 270. The cascade below is computed in a CANONICAL frame -- "the dock is on the
  # right", origin 0 -- exactly as before; lrect() maps a canonical rectangle onto the real
  # edge and CXQ reads a window's canonical inward position back out. The patch's
  # keystone (ksDockKeystone) rotates its warp by the same transform, so the trapezoid's
  # pinned edge is always the physical screen edge. W/H/RT/RR/RB below are canonical;
  # LW/LH are the logical size (the PiP, which stays bottom-right, uses those).
  EDGE=$(( t % 4 ))
  case "$EDGE" in
    0) W=$LW; H=$LH; RR=$r2; RT=$r1; RB=$r3; CXQ='(.at[0] - '"$X0"')' ;;
    1) W=$LH; H=$LW; RR=$r3; RT=$r0; RB=$r2; CXQ='(.at[1] - '"$Y0"')' ;;
    2) W=$LW; H=$LH; RR=$r0; RT=$r1; RB=$r3; CXQ='('"$LW"' - (.at[0] - '"$X0"' + .size[0]))' ;;
    3) W=$LH; H=$LW; RR=$r1; RT=$r0; RB=$r2; CXQ='('"$LH"' - (.at[1] - '"$Y0"' + .size[1]))' ;;
  esac
  # panel width scales with the viewport (~1/3 of the logical width -> 640 on a 1920 view,
  # 800 on a 2400 view), clamped so cards stay usable on very small / very large screens.
  DW=$((W/3)); [ "$DW" -lt 420 ] && DW=420; [ "$DW" -gt 900 ] && DW=900
  # Margins + cascade steps also scale with the viewport (were fixed 14/48/18/14 on a 1920
  # view). HGAP=0 -> the front card sits FLUSH to the right screen edge (no gap/trim).
  HGAP=$((W/60))                     # RIGHT INSET: how far the pile sits IN from the right
                                     # edge (~40 logical on a 2400 view ~= 0.5cm physical).
                                     # Divisor DOWN = more inset (W/30 ~1cm), UP = less.
  VGAP=$((H/28))                     # top/bottom margin (~48 on a 1350-tall view)
  # CASCADE DEPTH ("floating stack, receding"): back cards SHRINK by SHRINK% per depth and
  # their CENTER stays on the front card's midline (NO diagonal-down) -- they only drift a
  # little LEFT by DLEFT, so the pile reads as cards going back into the distance.
  DLEFT=$((DW/30))                   # per-depth LEFT drift of the card center (slight)
  SHRINK=9; MAXD=3                   # per-depth size shrink (%); deepest visible depth
  STAGGER=0.035                      # seconds between cards on show/park -> a bit of "feel"
  # canonical (origin 0): x runs toward the dock edge, y along it
  DOCK_Y=$((RT + VGAP))
  DOCK_H=$((H - RT - RB - 2*VGAP))
  SHOWN_X=$((W - RR - DW - HGAP))    # front (depth 0) x
  PARKED_X=$W                        # fully off the dock edge
}

# Canonical rectangle (x y w h) -> logical "x y w h" on the real edge (see geom).
lrect() {
  local x=$1 y=$2 w=$3 h=$4
  case "$EDGE" in
    0) echo "$(( X0 + x )) $(( Y0 + y )) $w $h" ;;
    1) echo "$(( X0 + y )) $(( Y0 + x )) $h $w" ;;
    2) echo "$(( X0 + W - x - w )) $(( Y0 + y )) $w $h" ;;
    3) echo "$(( X0 + y )) $(( Y0 + W - x - w )) $h $w" ;;
  esac
}
# A window's current canonical size "w h" and along-edge position y.
csize() { $J -r --arg a "$1" --argjson e "$EDGE" 'first(.[]|select(.address==$a)) | if ($e % 2) == 1 then "\(.size[1]) \(.size[0])" else "\(.size[0]) \(.size[1])" end' <<<"$CLIENTS"; }
cy_of() { $J -r --arg a "$1" --argjson e "$EDGE" --argjson x0 "$X0" --argjson y0 "$Y0" 'first(.[]|select(.address==$a)) | if ($e % 2) == 1 then .at[0] - $x0 else .at[1] - $y0 end' <<<"$CLIENTS"; }
# Move a window to canonical (x, y), keeping its size.
cmv() {
  local w h lx ly
  read -r w h < <(csize "$1"); { [ -n "${w:-}" ] && [ -n "${h:-}" ]; } || return 0
  read -r lx ly _ _ < <(lrect "$2" "$3" "$w" "$h")
  mv "$1" "$lx" "$ly"
}

# One clients snapshot per run; all reads parse it (positions are read before any
# move, so a single snapshot is consistent for the whole placement pass).
snap() { CLIENTS=$($HC clients -j); }
# A window being removed can still appear in the snapshot; EXCLUDE drops it from
# the layout (set by 'orphan' on window.close). Empty = exclude nothing.
EXCLUDE=""
# Dock-tagged windows: a rule tag renders as 'dock*', a dispatcher tag as 'dock';
# rtrimstr collapses both. Sorted by address for a stable cycle order.
# A "dock card" for the CASCADE = tagged dock but NOT pip. A PiP (my.sidedock keystone PiP)
# is tagged dock too (so it gets the keystone look/shadow/input for free) but pip excludes it
# from the pile, so it floats standalone wherever pip_make parked it.
order()    { $J -r --arg ex "$EXCLUDE" '[.[]|select((.tags|any(rtrimstr("*")=="dock")) and (.tags|any(rtrimstr("*")=="pip")|not) and .address != $ex)|.address]|sort|.[]' <<<"$CLIENTS"; }
# Current front = the on-screen dock window nearest the base (largest canonical x).
curfront() { $J -r --argjson px "$PARKED_X" '[.[]|select((.tags|any(rtrimstr("*")=="dock")) and (.tags|any(rtrimstr("*")=="pip")|not) and ('"$CXQ"' < $px))]|max_by('"$CXQ"')?|.address // ""' <<<"$CLIENTS"; }
shownany() { $J -r --argjson px "$PARKED_X" 'any(.[]; (.tags|any(rtrimstr("*")=="dock")) and (.tags|any(rtrimstr("*")=="pip")|not) and ('"$CXQ"' < $px))' <<<"$CLIENTS"; }
isfloat()  { $J -r --arg a "$1" 'first(.[]|select(.address==$a)).floating // false' <<<"$CLIENTS"; }
exists()   { $J -e --arg a "$1" 'any(.[]; .address==$a)' <<<"$CLIENTS" >/dev/null 2>&1; }

d() { $HC dispatch "$1" >/dev/null 2>&1; }   # fire a Lua dispatcher, ignore chatter
mv()   { d "hl.dsp.window.move({x=$2, y=$3, window=\"address:$1\"})"; }
op()   { d "hl.dsp.window.set_prop({prop=\"opacity\", value=\"$2\", window=\"address:$1\"})"; }
ztop() { d "hl.dsp.window.alter_zorder({mode=\"top\", window=\"address:$1\"})"; }
# Pin = show on EVERY workspace, so the dock follows whatever workspace is live
# instead of staying stuck on the one it opened on. on when it joins the dock,
# off when it leaves.
pin()  { d "hl.dsp.window.pin({action=\"$2\", window=\"address:$1\"})"; }
# no_focus on the BACK windows: clicking a peeking window then can't focus/raise
# it (which would jump it to the front out of turn). Only the front is focusable.
nofocus() { d "hl.dsp.window.set_prop({prop=\"no_focus\", value=\"$2\", window=\"address:$1\"})"; }
ensure_float() { [ "$(isfloat "$1")" = "false" ] && d "hl.dsp.window.float({window=\"address:$1\"})"; }

# The pile lives on its own SPECIAL workspace, `dock`, not on a regular one. Pinned-and-
# parked on a regular workspace, every card still belonged to it, so DMS's workspace strip
# drew it as an app icon of that workspace even while the dock was hidden. A special
# workspace is listed nowhere, overlays whatever workspace is live (so no pin is needed),
# and showing / hiding the dock shows / hides it, with the cards still sliding in and out
# on top. Its own, not the Mod+C scratchpad (`scratch`): sharing that one made Mod+C bring
# the dock along. Hyprland shows one special workspace per monitor at a time, so opening
# the dock closes the scratchpad and vice versa.
SPECIAL="special:dock"
in_dockws()    { $J -e --arg a "$1" --arg s "$SPECIAL" 'any(.[]; .address==$a and .workspace.name==$s)' <<<"$CLIENTS" >/dev/null 2>&1; }
to_dockws()   { in_dockws "$1" || d "hl.dsp.window.move({workspace=\"$SPECIAL\", follow=false, window=\"address:$1\"})"; }
# back to the regular workspace on the focused monitor (undock, PiP)
to_regular()   { local ws; ws=$($HC monitors -j | $J -r '.[]|select(.focused)|.activeWorkspace.id')
                 [ -n "$ws" ] && d "hl.dsp.window.move({workspace=\"$ws\", follow=false, window=\"address:$1\"})"; }
dockws_shown() { [ "$($HC monitors -j | $J -r --arg s "$SPECIAL" '.[]|select(.focused)|.specialWorkspace.name')" = "$SPECIAL" ]; }
# Open it without the dim: Hyprland captures decoration:dim_special when a special
# workspace opens, and the global value is the scratchpad's tint (features/hyprland).
dockws_show()  {
  dockws_shown && return 0
  local dim; dim=$($HC getoption decoration:dim_special -j 2>/dev/null | $J -r '.float // 0')
  $HC eval 'hl.config({ decoration = { dim_special = 0 } })' >/dev/null 2>&1
  d "hl.dsp.workspace.toggle_special(\"${SPECIAL#special:}\")"
  $HC eval "hl.config({ decoration = { dim_special = $dim } })" >/dev/null 2>&1
}
dockws_hide()  { dockws_shown && d "hl.dsp.workspace.toggle_special(\"${SPECIAL#special:}\")"; }

# Lay out the cascade with $1 as the front. Rotates the stable order so the front
# is depth 0, places each window at its depth (front at base, full opacity; the rest
# fanned+dimmed), raises deepest->front so the front lands on top, then focuses
# the front. All placement is by address; only the final focus touches focus.
render() {
  local front="$1" stagger="${2:-0}" i d dd x y cw ch cx cy op ov scp
  local -a ord rot MX MY
  mapfile -t ord < <(order)
  [ ${#ord[@]} -eq 0 ] && return 1
  local fi=0
  for i in "${!ord[@]}"; do [ "${ord[$i]}" = "$front" ] && fi=$i && break; done
  for ((i=0; i<${#ord[@]}; i++)); do rot+=("${ord[$(( (fi+i) % ${#ord[@]} ))]}"); done
  # Floating is a prerequisite AND a toggle, so it can't go in the batch; dock
  # windows are already floating, so this is normally a no-op.
  local a; for a in "${rot[@]}"; do ensure_float "$a"; to_dockws "$a"; done
  dockws_show
  # Front card vertical CENTRE -- back cards keep this SAME midline (no diagonal-down);
  # they only shrink and step a little LEFT, so their left edge peeks out to the left.
  local CY0=$(( DOCK_Y + DOCK_H/2 ))
  # ONE atomic batch (size, opacity, pin, focusability, z-order, focus) so nothing flashes
  # to the top mid-shuffle. The MOVE is in the batch ONLY when not staggering; on show it
  # is done per-card with a small delay below (the "feel"). NB back cards are ACTUAL smaller
  # windows (min==max lock) -- the app reflows to that size; that's the cost of real shrink.
  local batch=""
  for ((i=0; i<${#rot[@]}; i++)); do
    d=$i; dd=$(( d < MAXD ? d : MAXD )); a="${rot[$i]}"
    scp=$(( 100 - dd*SHRINK )); [ "$scp" -lt 55 ] && scp=55     # depth shrink (% of front, floored)
    cw=$(( DW*scp/100 )); ch=$(( DOCK_H*scp/100 ))
    x=$(( SHOWN_X - dd*DLEFT ))                                 # LEFT edge steps slightly left (peek)
    y=$(( CY0 - ch/2 ))                                         # vertically CENTERED on the front midline
    # canonical -> the real (physical-right) edge: logical position and size
    read -r x y cw ch < <(lrect "$x" "$y" "$cw" "$ch")
    MX[$i]=$x; MY[$i]=$y
    if [ "$d" -eq 0 ]; then op="1.0 1.0"; else ov=$(( 60 - (dd-1)*14 )); [ "$ov" -lt 30 ] && ov=30; op="0.$ov 0.$ov"; fi
    batch+="dispatch hl.dsp.window.set_prop({prop=\"max_size\", value=\"$cw $ch\", window=\"address:$a\"}) ; "
    batch+="dispatch hl.dsp.window.set_prop({prop=\"min_size\", value=\"$cw $ch\", window=\"address:$a\"}) ; "
    batch+="dispatch hl.dsp.window.resize({x=$cw, y=$ch, window=\"address:$a\"}) ; "
    batch+="dispatch hl.dsp.window.set_prop({prop=\"opacity\", value=\"$op\", window=\"address:$a\"}) ; "
    if [ "$d" -eq 0 ]; then batch+="dispatch hl.dsp.window.set_prop({prop=\"no_focus\", value=\"false\", window=\"address:$a\"}) ; "
    else                   batch+="dispatch hl.dsp.window.set_prop({prop=\"no_focus\", value=\"true\", window=\"address:$a\"}) ; "; fi
    [ "$stagger" != 1 ] && batch+="dispatch hl.dsp.window.move({x=$x, y=$y, window=\"address:$a\"}) ; "
  done
  # Raise deepest -> front so the front lands on top (all within the one frame).
  for ((i=${#rot[@]}-1; i>=0; i--)); do
    batch+="dispatch hl.dsp.window.alter_zorder({mode=\"top\", window=\"address:${rot[$i]}\"}) ; "
  done
  batch+="dispatch hl.dsp.focus({window=\"address:${rot[0]}\"})"
  $HC --batch "$batch" >/dev/null 2>&1
  # Staggered slide-in (show): front leads, each next card follows STAGGER later, so the
  # pile fans in with a bit of feel instead of snapping as one block. (Sizes/z were set
  # atomically above; only the visible position is staggered, so there is no flicker.)
  if [ "$stagger" = 1 ]; then
    for ((i=0; i<${#rot[@]}; i++)); do
      d "hl.dsp.window.move({x=${MX[$i]}, y=${MY[$i]}, window=\"address:${rot[$i]}\"})"
      [ "$i" -lt $(( ${#rot[@]} - 1 )) ] && sleep "$STAGGER" 2>/dev/null
    done
  fi
  printf '%s' "${rot[0]}" >"$STATE"
}

park_all() {
  # Slide the pile off to the right, BACK-to-FRONT with a small stagger so it ripples out
  # instead of leaving as one block (matches the staggered slide-IN on show). order() is
  # front..back, so reverse. The cards stay on the dock workspace; hide_pile closes it after.
  local -a o; mapfile -t o < <(order)
  local a i
  for ((i=${#o[@]}-1; i>=0; i--)); do a="${o[$i]}"; [ -n "$a" ] || continue
    ensure_float "$a"; cmv "$a" "$PARKED_X" "$DOCK_Y"
    if [ "$i" -gt 0 ]; then sleep "$STAGGER" 2>/dev/null; fi
  done
}
# Hide: remember the front, slide the cards out, then close the dock workspace.
hide_pile() {
  local cur; cur="$(curfront)"; [ -n "$cur" ] && printf '%s' "$cur" >"$STATE"
  park_all
  dockws_hide
}
# Shown = the dock workspace is up on this monitor AND a card is on-screen (opening the
# scratchpad closes the dock workspace with the cards still in place: that is hidden).
pile_shown() { [ "$(shownany)" = "true" ] && dockws_shown; }
# Show the pile at the remembered front (falling back to the first window).
show_pile() {
  local -a o; mapfile -t o < <(order); [ ${#o[@]} -eq 0 ] && return 1
  local want=""; [ -f "$STATE" ] && want="$(cat "$STATE" 2>/dev/null)"
  { [ -z "$want" ] || ! exists "$want"; } && want="${o[0]}"
  # Slide in from past the edge on the `dockshow` curve (gentle overshoot, sidedock/
  # hyprland.lua) at a slightly calmer speed, set ONCE for the whole slide-in: the move
  # animation's curve is read live, so it must not change while cards are moving. Back to
  # the plain dockslide only after the last card has had time to land (speed 6 = 600 ms).
  $HC eval 'hl.animation({ leaf = "windowsMove", enabled = true, speed = 6, bezier = "dockshow" })' >/dev/null 2>&1
  render "$want" 1
  ( sleep 0.8; $HC eval 'hl.animation({ leaf = "windowsMove", enabled = true, speed = 5, bezier = "dockslide" })' >/dev/null 2>&1 ) &
}
active() { $J -r '.address // ""' < <($HC activewindow -j); }
is_dock() { $J -e --arg a "$1" 'any(.[]; .address==$a and (.tags|any(rtrimstr("*")=="dock")))' <<<"$CLIENTS" >/dev/null 2>&1; }
is_pip()  { $J -e --arg a "$1" 'any(.[]; .address==$a and (.tags|any(rtrimstr("*")=="pip")))'  <<<"$CLIENTS" >/dev/null 2>&1; }
dock_chrome() {  # the auto-route rule's chrome, for a window docked after it opened
  d "hl.dsp.window.set_prop({prop=\"border_size\", value=\"0\", window=\"address:$1\"})"
  d "hl.dsp.window.set_prop({prop=\"rounding\", value=\"0\", window=\"address:$1\"})"
  d "hl.dsp.window.set_prop({prop=\"no_shadow\", value=\"false\", window=\"address:$1\"})"
}
dock_send() {  # give a window the dock shape + tag, then lay it out as the front
  local a="$1"
  ensure_float "$a"
  d "hl.dsp.window.tag({tag=\"+dock\", window=\"address:$a\"})"
  # (size + lock is applied by render(), from the live geometry -- not here.)
  # Match the auto-route rule's chrome: no BORDER (drawn at the flat box, not warped,
  # so it would box the trapezoid) and rounding 0 (the keystone shader draws the
  # corners). SHADOW and BLUR stay ON: the patch warps both to the trapezoid
  # (keystone_shadow_*), and that drop shadow is what makes the card read as lifted.
  # (Upstream still strips the shadow here with decorate=false + no_shadow, from
  # before the shadow was warped -- which left manually-docked cards shadowless.)
  # The RULE does this for cfg.apps; a sent window never hit it, so do it here.
  dock_chrome "$a"
  snap; render "$a"
}
undock() {  # strip the dock shape/tag and return a window to the tiling area
  local a="$1"
  # Clear the size LOCK first (so the window can retile freely): zero the min and
  # blow the max wide open -- no_max_size alone left the rule's 640x928 max in
  # force, which is the "no resize / janky" state. Then drop pin/dim/tag.
  d "hl.dsp.window.set_prop({prop=\"min_size\", value=\"0 0\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"max_size\", value=\"99999 99999\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_max_size\", value=\"true\", window=\"address:$a\"})"
  pin "$a" off
  nofocus "$a" false
  to_regular "$a"   # off the dock workspace, onto the one you are looking at
  d "hl.dsp.window.set_prop({prop=\"opacity\", value=\"1.0 1.0\", window=\"address:$a\"})"
  # restore the chrome dock_send stripped
  d "hl.dsp.window.set_prop({prop=\"decorate\", value=\"true\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_blur\", value=\"false\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"no_shadow\", value=\"false\", window=\"address:$a\"})"
  # Restore corner ROUNDING. The dock route-rule (sidedock/home.nix) pins rounding=0 so the
  # keystone SHADER owns the corners while docked; that per-window override survives undock,
  # leaving the window square in the tiling area. Re-apply the live GLOBAL rounding so it
  # rounds like every other window (read it, don't hardcode, so it tracks decoration:rounding).
  local grnd; grnd=$($HC getoption decoration:rounding -j 2>/dev/null | $J -r '.int // 10')
  d "hl.dsp.window.set_prop({prop=\"rounding\", value=$grnd, window=\"address:$a\"})"
  # ...and the border width dock_chrome zeroed, the same way.
  local gbrd; gbrd=$($HC getoption general:border_size -j 2>/dev/null | $J -r '.int // 0')
  d "hl.dsp.window.set_prop({prop=\"border_size\", value=$gbrd, window=\"address:$a\"})"
  d "hl.dsp.window.tag({tag=\"-dock\", window=\"address:$a\"})"
  # Tile it: read LIVE float state (not the pre-undock snapshot) and unfloat if
  # still floating, so it joins the layout like any normal app.
  [ "$($HC clients -j | $J -r --arg a "$a" 'first(.[]|select(.address==$a)).floating // false')" = "true" ] \
    && d "hl.dsp.window.float({window=\"address:$a\"})"
  snap
  # Re-lay whatever remains (only if the pile is on-screen) -- or, if that was the last
  # card, close the dock workspace rather than leave it open and empty -- then hand focus
  # back to the just-freed window: you pulled it out to use it.
  local -a o; mapfile -t o < <(order)
  if [ ${#o[@]} -eq 0 ]; then
    dockws_hide
  elif pile_shown; then
    render "${o[0]}"
  fi
  d "hl.dsp.focus({window=\"address:$a\"})"
}

# Size and park a PiP for the CURRENT geometry: fit the window's aspect inside ~1/3 of the
# viewport each way, bottom-right. pip_make uses it, and relayout re-runs it on every PiP
# so a rotation or scale change moves it to the new corner instead of leaving it at the
# old coordinates (off-screen after a landscape -> portrait turn).
pip_place() {   # $1 = window, $2 = "keep" to keep its current size (relayout)
  local a="$1" pw ph px py
  if [ "${2:-}" = keep ]; then
    # keep the size you gave it, clamped to the (possibly rotated) screen
    read -r pw ph < <($J -r --arg a "$a" 'first(.[]|select(.address==$a))|"\(.size[0]) \(.size[1])"' <<<"$CLIENTS")
    { [ -n "${pw:-}" ] && [ "$pw" -gt 0 ] 2>/dev/null; } || { pw=$((LW/3)); ph=$((LH/3)); }
    [ "$pw" -gt $(( LW - 2*HGAP )) ] && pw=$(( LW - 2*HGAP ))
    [ "$ph" -gt $(( LH - 2*VGAP )) ] && ph=$(( LH - 2*VGAP ))
  else
    # A third of the viewport each way, i.e. the SCREEN's aspect. The client is told it is
    # keystone_pip_zoom (default 3) times this box (trapezoid.patch, realToReportSize for
    # `pip`), so it lays out as it would fullscreen, and scale-to-fit shrinks that into the
    # box, filling it. Resize it by its edges or Mod+right-drag (tall works too: the layout
    # follows the box's shape); Mod+Alt+minus/equal change how small the content is drawn.
    pw=$((LW/3)); ph=$((LH/3))
  fi
  # Parked bottom-right, right edge inset by HGAP so the keystone's flush right edge sits
  # just off the screen edge.
  px=$(( X0 + LW - pw - HGAP )); py=$(( Y0 + LH - ph - VGAP ))
  # Loose bounds, not a lock (a dock card's min == max lock would forbid resizing): small
  # enough to shrink to a thumbnail, no larger than the screen.
  d "hl.dsp.window.set_prop({prop=\"min_size\", value=\"160 100\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"max_size\", value=\"$LW $LH\", window=\"address:$a\"})"
  d "hl.dsp.window.resize({x=$pw, y=$ph, window=\"address:$a\"})"
  mv "$a" "$px" "$py"
}
pip_make() {  # turn $1 into a keystone PiP: a standalone, pinned, tilted mini-card, bottom-right.
  local a="$1"
  ensure_float "$a"
  d "hl.dsp.window.tag({tag=\"+dock\", window=\"address:$a\"})"  # +dock => keystone tilt/shadow/input, all free
  d "hl.dsp.window.tag({tag=\"+pip\", window=\"address:$a\"})"   # +pip  => the cascade (order/curfront/shownany) skips it
  dock_chrome "$a"   # as dock_send: no border, keystone corners, warped shadow kept
  to_regular "$a"   # a pin needs a regular workspace; a card would be on the dock workspace
  pin "$a" on
  pip_place "$a"
  ztop "$a"
  # If $a was a pile member (SUPER+P straight from the dock = the "pin clears dock" half), the
  # cascade now has a gap -- re-flow the survivors (order() already excludes this +pip window),
  # then hand focus back to the PiP.
  snap
  local -a o; mapfile -t o < <(order)
  if [ ${#o[@]} -eq 0 ]; then
    dockws_hide   # that was the last card: never leave the dock workspace open and empty
  elif pile_shown; then
    render "${o[0]}"
  fi
  d "hl.dsp.focus({window=\"address:$a\"})"
}
unpip() {  # return a PiP to the tiling area -- drop the pip tag, then reuse undock's full restore
  local a="$1"
  d "hl.dsp.window.tag({tag=\"-pip\", window=\"address:$a\"})"
  undock "$a"
}
dock_from_pip() {  # SUPER+CTRL+S on a PiP: fold it into the cascade pile instead of undocking it.
  # pin and dock are mutually exclusive, so docking a pinned window clears the pin. Drop the
  # standalone `pip` marker + its mini size-lock, but KEEP the `dock` tag (= the keystone look)
  # and the pin-on; then let render() resize it to the pile card size as the new front. Without
  # this, SUPER+CTRL+S hit undock() (a PiP carries `dock` too) and stranded it out of the pile,
  # still pip-tagged + mini-sized -- the limbo this whole change removes.
  local a="$1"
  d "hl.dsp.window.tag({tag=\"-pip\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"min_size\", value=\"0 0\", window=\"address:$a\"})"
  d "hl.dsp.window.set_prop({prop=\"max_size\", value=\"99999 99999\", window=\"address:$a\"})"
  snap; render "$a"
}

geom; snap
case "${1:-toggle}" in
  toggle)   # SUPER+S: show the pile if hidden, park it if shown
    if pile_shown; then hide_pile; else show_pile; fi ;;
  show)     # directional gesture (3-finger swipe toward the dock): reveal the pile.
            # Idempotent -- a no-op if it is already shown, so repeated swipes don't flicker.
    pile_shown || show_pile ;;
  hide)     # directional gesture (3-finger swipe away): hide the pile. Remembers the front
            # (like toggle) so the next show restores it. No-op if already hidden.
    pile_shown && hide_pile ;;
  next|prev)   # SUPER+ALT+right / SUPER+ALT+left while focused on the dock: shift the pile
    mapfile -t ORD < <(order)
    [ ${#ORD[@]} -eq 0 ] && exit 0
    pile_shown || { show_pile; exit 0; }   # not shown -> just show it
    [ ${#ORD[@]} -eq 1 ] && exit 0                          # safeguard: nothing to shift
    cur="$(curfront)"; ci=0
    for i in "${!ORD[@]}"; do [ "${ORD[$i]}" = "$cur" ] && ci=$i && break; done
    if [ "$1" = "next" ]; then ni=$(( (ci+1) % ${#ORD[@]} )); else ni=$(( (ci-1+${#ORD[@]}) % ${#ORD[@]} )); fi
    render "${ORD[$ni]}" ;;
  gesture-move)  # Release of a 3-finger swipe that began on a pile card. Hyprland's move
                 # gesture (trapezoid.patch) has already moved the swiped card under the finger
                 # and hands over $2 = l / r / none (the FINGER direction, or too short) and
                 # $3 = the front card at swipe start. Finger LEFT = next, like the 4-finger
                 # tape swipe and the workspace swipe; none = spring back. Either way render()
                 # animates the pile from wherever the finger left the card.
    mapfile -t ORD < <(order); [ ${#ORD[@]} -eq 0 ] && exit 0
    # $3 (the patch picks the largest logical x) is only right with the dock on the right;
    # on another edge (rotated screen) work the front out canonically instead
    cur="${3:-}"; [ "$EDGE" -ne 0 ] && cur=""
    { [ -n "$cur" ] && exists "$cur"; } || cur="$(curfront)"
    [ -z "$cur" ] && cur="${ORD[0]}"
    ci=0; for i in "${!ORD[@]}"; do [ "${ORD[$i]}" = "$cur" ] && ci=$i && break; done
    case "${2:-}" in
      l) render "${ORD[$(( (ci+1) % ${#ORD[@]} ))]}" ;;
      r) render "${ORD[$(( (ci-1+${#ORD[@]}) % ${#ORD[@]} ))]}" ;;
      *) render "$cur" ;;
    esac ;;
  dock-toggle)   # SUPER+CTRL+S: toggle the focused window's DOCK membership. pin and dock are
                 # mutually exclusive: a PiP (pin) folds into the pile (clearing the pin); a pile
                 # window undocks; a normal window docks. Check pip FIRST -- a PiP also carries the
                 # `dock` tag (for the keystone), so is_dock would otherwise catch it and undock it
                 # into limbo (out of the pile but still pip-tagged + mini-sized -- the old bug).
    a="$(active)"; [ -z "$a" ] && exit 0
    if   is_pip  "$a"; then dock_from_pip "$a"
    elif is_dock "$a"; then undock "$a"
    else                    dock_send "$a"; fi ;;
  pip-zoom)      # Mod+Alt+minus / equal: draw PiP content smaller (out) or larger (in), by
                 # scaling decoration:keystone_pip_zoom -- how many times the box the client is
                 # told it is -- by 1.25 within 1..8. Every PiP is nudged so it is re-told.
    z=$($HC getoption decoration:keystone_pip_zoom -j 2>/dev/null | $J -r '.float // 3')
    z=$(awk -v z="$z" -v d="${2:-out}" 'BEGIN { z = (d == "in") ? z / 1.25 : z * 1.25; if (z < 1) z = 1; if (z > 8) z = 8; printf "%.3f", z }')
    $HC eval "hl.config({ decoration = { keystone_pip_zoom = $z } })" >/dev/null 2>&1
    while read -r p; do
      [ -n "$p" ] || continue
      d "hl.dsp.window.resize({x=1, y=0, relative=true, window=\"address:$p\"})"
      d "hl.dsp.window.resize({x=-1, y=0, relative=true, window=\"address:$p\"})"
    done < <($J -r '.[]|select(.tags|any(rtrimstr("*")=="pip"))|.address' <<<"$CLIENTS") ;;
  pip-toggle)    # SUPER+P: toggle the focused window as a keystone picture-in-picture / "pin" --
                 # a standalone, pinned, tilted mini-card bottom-right -- or return it to the layout
                 # if already pinned. pip_make clears pile membership (the "pin clears dock" half).
    a="$(active)"; [ -z "$a" ] && exit 0
    if is_pip "$a"; then unpip "$a"; else pip_make "$a"; fi ;;
  adopt)   # a window ($2) was just BORN a card: the Lua window.open_early handler gave it
           # the DYNAMIC dock tag before its first frame, and the window rules floated it
           # card-sized just past the right edge. (A rule tag would render as "dock*",
           # which the tag dispatcher cannot remove, so undock could never release it --
           # hence dynamic.) Re-tag for safety, re-snapshot so order() sees it, then
           # cascade it to the front: render's move slides it in from the side.
    exists "$2" || exit 0
    d "hl.dsp.window.tag({tag=\"+dock\", window=\"address:$2\"})"
    snap
    render "$2" ;;
  stray)   # a window ($2) opened ON the dock workspace without joining the pile (a dialog,
           # or anything opened while the workspace had focus but no card did). The dock
           # workspace holds only cards: move it to the live regular workspace, and close
           # the dock workspace if the pile is empty so focus goes back to that workspace.
    exists "$2" || exit 0
    { is_dock "$2" || is_pip "$2"; } && exit 0
    in_dockws "$2" || exit 0
    to_regular "$2"
    # The dock workspace's window rule floated it card-sized past the right edge (modal
    # dialogs excepted), so hand it back to the layout as a normal window.
    [ "$(isfloat "$2")" = "true" ] && d "hl.dsp.window.float({window=\"address:$2\"})"
    snap; mapfile -t ORD < <(order); [ ${#ORD[@]} -eq 0 ] && dockws_hide
    d "hl.dsp.focus({window=\"address:$2\"})" ;;
  orphan)  # a dock window ($2) just CLOSED: re-flow the survivors (if the pile is up)
    EXCLUDE="$2"; snap
    mapfile -t ORD < <(order)
    # Dock now empty: close the dock workspace too. Left open and empty it kept focus, so
    # the next app opened ON it as a plain tiled window -- an unmarked special workspace
    # that looked like a normal one and that Mod+C could not get you out of.
    [ ${#ORD[@]} -eq 0 ] && { : >"$STATE"; dockws_hide; exit 0; }
    # Keep the remembered front if it survives; otherwise take the first.
    want=""; [ -f "$STATE" ] && want="$(cat "$STATE" 2>/dev/null)"
    if [ -z "$want" ] || [ "$want" = "$EXCLUDE" ] || ! printf '%s\n' "${ORD[@]}" | grep -qxF "$want"; then want="${ORD[0]}"; fi
    pile_shown && render "$want"
    printf '%s' "$want" >"$STATE" ;;
  relayout)  # the monitor layout/scale changed (e.g. wdisplays) -> re-apply the CURRENT
             # geometry in place from the fresh geom(), so a live resolution/scale change
             # auto-adjusts the pile with no keypress. Shown -> re-cascade at the new size/
             # position; parked -> re-park at the new (logical) off-screen x.
    if pile_shown; then
      cur="$(curfront)"; { [ -z "$cur" ] || ! exists "$cur"; } && cur="$(order | head -1)"
      [ -n "$cur" ] && render "$cur"
    else
      park_all
    fi
    # PiPs are outside the pile: move each to the new bottom-right corner, re-sized
    while read -r p; do [ -n "$p" ] && pip_place "$p" keep; done \
      < <($J -r '.[]|select(.tags|any(rtrimstr("*")=="pip"))|.address' <<<"$CLIENTS") ;;
esac
