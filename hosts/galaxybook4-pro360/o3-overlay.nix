final: prev:
let
  # Append -O3 to whichever location the package uses for NIX_CFLAGS_COMPILE.
  # nixpkgs forbids the same var appearing in both `env` and top-level args.
  o3 = pkg: pkg.overrideAttrs (old:
    if (old.env or { }) ? NIX_CFLAGS_COMPILE
    then { env = old.env // { NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " -O3"; }; }
    else { NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -O3"; }
  );

  packages = [
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
    "sqlite" "diffutils" "ccache"

    # Developer toolchain
    "nix" "git" "mold"

    # Serialization / data processing
    "protobuf" "jq" "abseil-cpp"

    # Language runtimes
    "python3"

    # Crypto (compute-bound paths)
    "argon2"

    # Storage engines
    "redis" "lmdb"
  ];
in
builtins.listToAttrs (
  map (name: { inherit name; value = o3 prev.${name}; }) packages
)
