final: prev:
let
  # Append LTO/pipe flags to whichever location the package uses for
  # NIX_CFLAGS_COMPILE / NIX_CFLAGS_LINK. nixpkgs forbids the same var
  # appearing in both `env` and top-level args (same constraint o3-overlay.nix
  # already works around).
  #
  # NOT a stdenv-wide override: overriding stdenv/stdenv.cc directly in an
  # overlay re-enters nixpkgs' own multi-stage bootstrap chain (booter.nix)
  # and causes infinite recursion, even for plain native builds. Per-package
  # overrideAttrs (like this, and like o3-overlay.nix) is the only safe way
  # to apply compiler flags broadly without touching stdenv construction itself.
  addFlags = pkg: pkg.overrideAttrs (old:
    let
      compileFlags = "-pipe -flto=auto -ffat-lto-objects";
      linkFlags = "-flto=auto";
      envOverrides =
        (if (old.env or { }) ? NIX_CFLAGS_COMPILE
          then { NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " " + compileFlags; }
          else { NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " " + compileFlags; })
        // (if (old.env or { }) ? NIX_CFLAGS_LINK
          then { NIX_CFLAGS_LINK = old.env.NIX_CFLAGS_LINK + " " + linkFlags; }
          else { NIX_CFLAGS_LINK = (old.NIX_CFLAGS_LINK or "") + " " + linkFlags; });
    in
    if old ? env then
      { env = old.env // envOverrides; }
    else
      envOverrides
  );

  # Packages o3-overlay.nix (galaxybook4-pro360 only, not used on victus-15)
  # already applies its own overrideAttrs to. Stacking a second, separate
  # overrideAttrs call on the same package here confuses nixpkgs' env/
  # top-level attribute tracking (observed: "attribute cannot exist in both
  # env and derivation arguments" once two independent overlays each
  # overrideAttrs the same package). Skip these entirely here; they already
  # get -O3 from o3-overlay.nix. Kept in sync manually with that file's list.
  o3OverlayPackages = [
    "zstd" "zlib" "lz4" "xz" "brotli" "snappy" "bzip2" "zopfli" "libarchive"
    "ffmpeg" "opus" "dav1d" "libaom" "libvpx" "libwebp"
    "libvorbis" "flac" "lame" "libsamplerate" "mpg123"
    "x264" "x265"
    "harfbuzz" "freetype" "pango"
    "pcre2" "icu" "libxml2"
    "mesa" "cairo" "pixman" "lcms2" "libpng"
    "poppler" "mupdf" "imagemagick"
    "wlroots" "gtk4" "glib" "libxkbcommon" "pipewire"
    "tree-sitter"
    "sqlite" "diffutils" "ccache"
    "nix" "git" "mold"
    "protobuf" "jq" "abseil-cpp"
    "argon2"
    "redis" "lmdb"
  ];

  packages = [
    # Compression
    "lzo" "lzip" "zpaq" "p7zip"

    # Media codecs
    "libtheora" "speex" "wavpack" "libass" "svt-av1"

    # Fonts and text shaping
    "fontconfig"

    # Regex / Unicode / XML / JSON
    "pcre" "libxslt" "oniguruma" "simdjson" "yyjson" "jsoncpp"

    # Rendering
    "libjpeg" "libjpeg_turbo" "giflib" "librsvg"

    # Document / image processing
    "poppler_utils" "exiv2" "libraw" "graphicsmagick"

    # Wayland / GUI stack
    "gtk3" "sdl2" "sdl3"

    # System libraries and tools
    "ripgrep" "fd" "bat" "fzf" "util-linux"

    # Serialization / data processing
    "capnproto" "flatbuffers" "msgpack-c"

    # Crypto (compute-bound paths)
    "openssl" "libsodium" "mbedtls" "gnutls"

    # Storage engines
    "leveldb" "rocksdb"

    # Networking
    "curl" "nghttp2" "c-ares" "libssh2"

    # Numeric / scientific
    "fftw" "fftwFloat" "openblas" "gsl"

    # Shell / terminal
    "tmux" "ncurses" "readline" "zsh" "fish"
  ];

  # Only apply to packages that actually exist as top-level attrs (some of
  # the names above may not be defined depending on the nixpkgs revision),
  # and skip anything o3-overlay.nix already touches.
  existingPackages = builtins.filter
    (name: (prev ? ${name}) && !(builtins.elem name o3OverlayPackages))
    packages;
in
builtins.listToAttrs (
  map (name: { inherit name; value = addFlags prev.${name}; }) existingPackages
)
