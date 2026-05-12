{ ... }:

{
  /*
    HHKB-style layout (everywhere: TTY, greetd, niri, Emacs, …) via https://github.com/rvaiya/keyd
    Caps: tap Escape, hold Control. Physical Escape → Caps Lock.

    Physical Right Alt is remapped at evdev/uinput layer to Hangul/Eisu (`hangeul`), so apps never receive
    `Alt`-modifier combos from RAlt — fcitx5 binds IME switching to the Hangul key instead (Home Manager).
    Verify names with `sudo keyd monitor`; list key codes with `sudo keyd list-keys | rg hangeul`.
  */
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings = {
        main = {
          capslock = "overload(control, esc)";
          esc = "capslock";
          rightalt = "hangeul";
        };
      };
    };
  };
}
