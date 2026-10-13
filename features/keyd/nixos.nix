{ config, lib, ... }:

let
  cfg = config.my.keyd;

  # Per-layout keyd main-section remaps. keyd rewrites at the evdev/uinput layer, so whichever is
  # chosen applies EVERYWHERE -- TTY, greetd, the compositor, Emacs -- not per-session.
  layouts = {
    # HHKB-style: Caps = tap Escape / hold Control; physical Escape = Caps Lock; Right Alt = Hangul,
    # so apps never receive an Alt-modifier from RAlt -- fcitx5 binds IME switching to the Hangul key
    # instead (see the fcitx feature's home half). Verify names with `sudo keyd monitor`; list codes
    # with `sudo keyd list-keys | rg hangeul`.
    hhkb = {
      capslock = "overload(control, esc)";
      esc = "capslock";
      rightalt = "hangeul";
    };
    # Caps alone emits Hangul, nothing else. PLAIN remap, NOT timeout(hangeul, 200, capslock): a
    # tap-hold macro makes keyd hold events for up to 200ms to disambiguate tap vs hold, which lags
    # every Caps press. The plain remap fires instantly and never buffers; the hold-for-real-capslock
    # is dropped, which is fine -- this key is never used for Caps Lock here.
    capsHangul = {
      capslock = "hangeul";
    };
  };
in
{
  options.my.keyd = {
    enable = lib.mkEnableOption ''
      key remapping via keyd. Applies everywhere -- TTY, greetd, the compositor, Emacs -- because it
      rewrites at the evdev/uinput layer rather than per-session. Pick the remap with my.keyd.layout
    '';

    layout = lib.mkOption {
      type = lib.types.enum (lib.attrNames layouts);
      default = "hhkb";
      description = ''
        Which keyd remap to apply:
          "hhkb"       - Caps = tap Esc / hold Ctrl, Esc = Caps Lock, Right Alt = Hangul (HHKB feel).
          "capsHangul" - Caps emits Hangul (plain, instant remap), nothing else.
      '';
    };

    perDevice = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = { };
      example = lib.literalExpression ''{ "001f:0b26" = { leftalt = "leftmeta"; leftmeta = "leftalt"; }; }'';
      description = ''
        Per-keyboard `main`-section remaps, keyed by the device's `vendor:product` id (find it in the
        `keyd` journal's DEVICE lines or `sudo keyd list-keyboards` -- NOT /proc, whose name<->id
        pairing can mislead). Each listed id is EXCLUDED from the default `*` config and instead gets
        the chosen `layout` MERGED WITH these remaps (a key here overrides the same key in `layout`),
        so one external board can tweak a few keys while still inheriting the rest of the layout --
        e.g. keep capslock=hangeul and only swap Alt<->Win. Values are keyd key names; note it is
        `leftcontrol`, NOT `leftctrl` (keyd silently rejects the latter as "not a valid key").
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.keyd = {
      enable = true;
      keyboards =
        {
          # Everything EXCEPT the per-device boards below. keyd's `[ids]` takes `*` plus `-<id>`
          # exclusions, so excluding here is order-independent (no reliance on config filename sort).
          default = {
            ids = [ "*" ] ++ map (id: "-${id}") (lib.attrNames cfg.perDevice);
            settings.main = layouts.${cfg.layout};
          };
        }
        # One keyd config per per-device board (its own [ids] + [main]). Name is derived from the id
        # (":" -> "_") only to form a valid attr/filename; keyd matches on the `ids` value, not the name.
        // lib.mapAttrs'
          (id: remaps: lib.nameValuePair "dev-${lib.replaceStrings [ ":" ] [ "_" ] id}" {
            ids = [ id ];
            # Inherit the chosen layout, then overlay this device's remaps (device keys win).
            settings.main = layouts.${cfg.layout} // remaps;
          })
          cfg.perDevice;
    };
  };
}
