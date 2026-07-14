{ inputs, system }:
let
  # Fresh, independent nixpkgs evaluation via the flake input directly --
  # NOT via `prev`/`pkgs.path` from inside an overlay. Using `prev` (a
  # partially constructed fixpoint mid-overlay-chain) or `import pkgs.path {}`
  # both triggered genuine infinite recursion (observed at two different
  # points in nixpkgs' own internals: pkgs/top-level/by-name-overlay.nix and
  # aliases.nix) once this walks buildInputs/propagatedBuildInputs across
  # hundreds of packages. Going through `inputs.nixpkgs` directly sidesteps
  # the fixpoint entanglement entirely -- confirmed working (402-package
  # closure, no recursion) where the other two approaches failed.
  freshPkgs = import inputs.nixpkgs { inherit system; };

  # "Anchor" packages: everything actually installed (environment.systemPackages
  # / home.packages / account package lists) across both hosts. Kept in sync
  # manually with those files -- this is the one place manual curation is
  # unavoidable, since NixOS overlays are evaluated before
  # environment.systemPackages (which references the already-overlaid pkgs),
  # so an overlay structurally cannot look up "what's installed" itself.
  anchorNames = [
    # accounts/r0k0r.nix
    "cursor-cli" "kitty" "fish" "git" "gh" "starship" "nixd" "statix" "deadnix"
    "tree" "python3" "basedpyright" "gcc" "gdb" "flutter" "dart" "tinymist" "typst"
    # packages/common.nix
    "wget" "openvpn" "upower"
    # packages/hosts/galaxybook4-pro360.nix
    "ffmpeg-full" "rnote" "siril" "blender" "easyeffects" "moonlight-qt"
    "adwaita-icon-theme" "google-chrome" "opencode" "opencode-claude-auth" "zoom"
    "libva-utils" "powertop" "s-tui" "arduino-cli" "libreoffice"
    "bibata-cursors-translucent"
    # packages/accounts/hosts/galaxybook4-pro360.nix
    "nixfmt" "biber"
    # hosts/victus-15/packages.nix
    "vim" "tailscale" "nbfc-linux" "ryzenadj"
  ];

  anchorPackages =
    (builtins.filter (p: p != null) (map (name: freshPkgs.${name} or null) anchorNames))
    ++ [
      freshPkgs.kdePackages.dolphin
      freshPkgs.kdePackages.kdeconnect-kde
      freshPkgs.kdePackages.qt6ct
      freshPkgs.kdePackages.breeze-icons
      freshPkgs.kdePackages.kdenlive
    ];

  keyOf = pkg: pkg.pname or pkg.name or "unknown";

  # Transitive closure of buildInputs/propagatedBuildInputs only -- the actual
  # runtime dependency edges (things that get linked in and can execute at
  # host runtime). Deliberately excludes nativeBuildInputs (build-time-only
  # edges: code generators, parser generators, etc. that never end up in the
  # resulting binary).
  runtimeClosure = builtins.genericClosure {
    startSet = map (pkg: { key = keyOf pkg; inherit pkg; }) anchorPackages;
    operator =
      { pkg, ... }:
      map (p: { key = keyOf p; pkg = p; })
        (builtins.filter (p: p ? pname || p ? name)
          ((pkg.buildInputs or [ ]) ++ (pkg.propagatedBuildInputs or [ ])));
  };

  runtimeNames = map (item: item.key) runtimeClosure;
in
{
  isHostRuntime = pkgName: builtins.elem pkgName runtimeNames;
  inherit runtimeNames;
}
