{ pkgs, ... }:

with pkgs;
[
  google-chrome
  bluez
  blueman
  zip

  rust-analyzer
  cargo
  typescript-language-server

  cmake
  ninja
  pkg-config
  gtk3
  libepoxy
  libwpe
  libwpe-fdo

  (texlive.combine {
    inherit (texlive)
      scheme-full
      graphics
      amsmath
      latexmk
      ;
  })
]
