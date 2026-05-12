{ pkgs, ... }:

{
  # List packages installed in your system profile.
  # You can use https://search.nixos.org/ to find packages and options.
  environment.systemPackages = with pkgs; [
    wget
    cursor-cli
    kitty
    fish
    git
    upower
    openvpn
    gh
    nixd
    nixfmt-rfc-style
    statix
    deadnix
    nautilus
    kdePackages.kdeconnect-kde
    kdePackages.qt6ct

    /*
      fcitx5 tray (Classic UI StatusNotifier): requests Icon `input-keyboard-symbolic` (see dbus
      `:…/StatusNotifierItem` IconName). That lives in KDE/GNOME themes, not in hicolor-only trees,
      otherwise QuickShell shows the magenta fallback tile.
    */
    kdePackages.breeze-icons
    adwaita-icon-theme

    python3
    /* Python LSP for Emacs `lsp-pyright` when using BasedPyright (`basedpyright-langserver`). */
    basedpyright

    gcc
    gdb

    flutter
    dart

    (pkgs.texlive.combine {
      inherit (pkgs.texlive)
        scheme-medium # Base (basic, small, medium, or full)
        graphics # Specific collections
        amsmath # Specific packages
        latexmk # Build automation tool
        ;
    })
  ];
}
