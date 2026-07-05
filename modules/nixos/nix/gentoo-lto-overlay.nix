{ hostRuntimeClassifier }:
final: prev:
# nixpkgs' own stdenv bootstrap chain (pkgs/stdenv/booter.nix) re-evaluates
# the entire overlay list fresh for each bootstrap stage, with that stage's
# own minimal stdenv already substituted in from the start -- this overlay
# genuinely runs again standalone inside bootstrap stages, not just once for
# the final package set. Confirmed by a real build failure: m4 built at
# bootstrap-stage1 (an i686 static-toolchain stage with no LTO plugin
# support) got "-pipe -flto=auto -ffat-lto-objects" injected via this same
# overlay and failed its own "C compiler cannot create executables" check.
# The final stdenv is named "stdenv-linux"; every bootstrap stage's stdenv
# name contains "bootstrap" (e.g. "bootstrap-stage1-stdenv-linux") -- skip
# the whole overlay during those stages rather than trying to guess which
# specific packages might get pulled into bootstrap construction.
if builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null then
  { }
else
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

  # Packages o3-overlay.nix already applies its own overrideAttrs to.
  # Stacking a second, separate
  # overrideAttrs call on the same package here confuses nixpkgs' env/
  # top-level attribute tracking (observed: "attribute cannot exist in both
  # env and derivation arguments" once two independent overlays each
  # overrideAttrs the same package). Skip these entirely here. Kept in sync
  # manually with that file's own candidate list.
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

  # Full candidate universe -- every package considered for LTO tuning,
  # regardless of whether it turns out to be a genuine host-runtime dependency
  # or purely a build-time tool. host-runtime-classifier.nix (checked below)
  # is what actually decides which treatment each one gets.
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

  # Only consider packages that actually exist as top-level attrs (some names
  # may not be defined depending on the nixpkgs revision), and skip anything
  # o3-overlay.nix already claims.
  existingPackages = builtins.filter
    (name: (prev ? ${name}) && !(builtins.elem name o3OverlayPackages))
    packages;

  # isHostRuntime: does ANYTHING actually installed (environment.systemPackages
  # / home.packages, see host-runtime-classifier.nix's anchor list) reference
  # this package via buildInputs/propagatedBuildInputs (a genuine runtime
  # dependency edge) anywhere in its transitive closure -- as opposed to only
  # ever being pulled in via nativeBuildInputs (a build-time-only edge, e.g.
  # a parser generator whose output gets compiled in and never invoked again)?
  #
  # host-runtime = true: tune the shared top-level attribute directly, same
  # as every other package here -- something genuinely executes this code on
  # the host, so tuning provides real benefit.
  #
  # host-runtime = false: leave the top-level attribute untouched (protects
  # every nativeBuildInputs consumer -- e.g. the bootstrap-stage m4 failure --
  # from blast radius that provides zero benefit, since nothing runs this on
  # host anyway) and expose only a "<name>-tuned" variant, available to
  # install explicitly if this ever becomes something run directly.
  hostRuntimeNames = builtins.filter hostRuntimeClassifier.isHostRuntime existingPackages;
  buildOnlyNames = builtins.filter (n: !(hostRuntimeClassifier.isHostRuntime n)) existingPackages;
in
(builtins.listToAttrs (
  map (name: { inherit name; value = addFlags prev.${name}; }) hostRuntimeNames
))
// (builtins.listToAttrs (
  map (name: { name = name + "-tuned"; value = addFlags prev.${name}; }) buildOnlyNames
))
