/*
  The DEFAULT candidate lists of the o3 and lto levers -- every package each
  lever may touch, before the classifier decides which of them are host-
  runtime (tuning/runtime-cache/lookup.nix). They used to live inside
  overlays/o3.nix and overlays/gentoo-lto.nix; they are the defaults of
  my.tuning.{o3,lto}.candidates now, so a host can change them without
  editing an overlay. Moved verbatim, comments included.
*/
{
  o3 = [
    # Compression
    "zstd" "zlib" "lz4" "xz" "brotli" "snappy" "bzip2" "zopfli" "libarchive"

    # Media codecs
    "ffmpeg" "opus" "dav1d" "libaom" "libvpx" "libwebp"
    "libvorbis" "flac" "lame" "libsamplerate" "mpg123"
    "x264" "x265"

    # Fonts and text shaping
    "harfbuzz" "freetype" "pango"

    # Regex / Unicode / XML
    "pcre2" "icu" "libxml2"

    # Rendering
    "mesa" "cairo" "pixman" "lcms2" "libpng"

    # Document / image processing
    "poppler" "mupdf" "imagemagick"

    # Wayland / GUI stack
    "wlroots" "gtk4" "glib" "libxkbcommon" "pipewire"

    # Tree-sitter (Emacs / editor parsing)
    "tree-sitter"

    # System libraries and tools
    # sqlite deliberately excluded: -O3 causes a genuine correctness bug, not
    # just a build failure. Confirmed via sqlite's own tcltest suite: 1 error
    # out of 400028 tests (like-14.2, the LIKE operator) under -O3. SQLite's
    # C code relies on careful patterns (fallthrough switches, pointer
    # aliasing, integer overflow handling) that aggressive optimizers can
    # silently miscompile -- well-documented sqlite build-flag sensitivity,
    # not a one-off fluke. This also matters more than most: nix itself uses
    # sqlite for its own store database.
    "diffutils" "ccache"

    # Developer toolchain (mostly build-time-only in practice -- see classifier)
    "nix" "git" "mold"

    # Serialization / data processing
    "protobuf" "jq" "abseil-cpp"

    # Crypto (compute-bound paths)
    "argon2"

    # Storage engines
    "redis" "lmdb"
  ];

  lto = [
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

    # Developer toolchain (mostly build-time-only in practice -- see classifier)
    "cmake" "ninja" "meson"

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

    # Parsing / build tooling (mostly build-time-only in practice -- see classifier)
    "bison" "flex" "m4"

    # Shell / terminal
    "tmux" "ncurses" "readline" "zsh" "fish"
  ];
}
