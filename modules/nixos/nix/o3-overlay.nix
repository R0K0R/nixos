{ hostRuntimeClassifier }:
final: prev:
# Same bootstrap-stage guard as gentoo-lto-overlay.nix: nixpkgs' own stdenv
# bootstrap chain re-evaluates the whole overlay list fresh per stage, with
# that stage's minimal stdenv already substituted in -- -O3 in an early
# bootstrap toolchain is the same class of risk LTO already demonstrated
# (see gentoo-lto-overlay.nix's comment for the m4 build failure this guards
# against).
if builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null then
  { }
else
let
  # Append -O3 to whichever location the package uses for NIX_CFLAGS_COMPILE.
  # nixpkgs forbids the same var appearing in both `env` and top-level args.
  o3 = pkg: pkg.overrideAttrs (old:
    if (old.env or { }) ? NIX_CFLAGS_COMPILE
    then { env = old.env // { NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " -O3"; }; }
    else { NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -O3"; }
  );

  # Full candidate universe -- host-runtime-classifier.nix decides which
  # treatment each one actually gets (see gentoo-lto-overlay.nix for the
  # full rationale, shared between both overlays).
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

  existingPackages = builtins.filter (name: prev ? ${name}) packages;

  # See gentoo-lto-overlay.nix for the full rationale: host-runtime = true
  # means something actually installed (environment.systemPackages /
  # home.packages) transitively references this package via buildInputs /
  # propagatedBuildInputs -- a genuine runtime dependency, so tuning the
  # shared top-level attribute directly is safe and beneficial. host-runtime
  # = false means it's only ever pulled in as a nativeBuildInputs (build-time
  # tool) -- tune only a separate "<name>-tuned" variant instead, leaving the
  # shared attribute untouched to protect its build-time consumers.
  hostRuntimeNames = builtins.filter hostRuntimeClassifier.isHostRuntime existingPackages;
  buildOnlyNames = builtins.filter (n: !(hostRuntimeClassifier.isHostRuntime n)) existingPackages;
in
(builtins.listToAttrs (
  map (name: { inherit name; value = o3 prev.${name}; }) hostRuntimeNames
))
// (builtins.listToAttrs (
  map (name: { name = name + "-tuned"; value = o3 prev.${name}; }) buildOnlyNames
))
