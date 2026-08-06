/*
  Tier 2 of the host-runtime classifier (see runtime-cache/lookup.nix):
  a cached eval-time heuristic, refreshed manually via refresh-tier2.sh, not
  computed on every rebuild. This is the backup/heuristic layer -- Tier 1
  (the live nix-store requisites of a real switched-to system) is the source
  of truth; this fills the gap before a package has actually been switched to.

  Builds its own throwaway "pass1" NixOS+home-manager evaluation for one host,
  with all NixOS-level tuning overlays force-emptied (o3-overlay.nix,
  gentoo-lto-overlay.nix, upstream-tools-overlay.nix, and every per-package
  fixup in that host's own overlay list) -- deliberately sidesteps the
  pass1Config/mkHost{pass1=true} wiring gap flake.nix never built, rather than
  resolving it: this file is invoked standalone (nix eval -f ... --argstr
  host ...), never as part of flake.nix's own overlay list, so the
  eval-needs-pkgs-needs-overlays-needs-eval cycle that motivated that
  parameter in the first place never arises here.

  ANCHOR DISCOVERY: extends host-runtime-classifier.nix's sibling
  runtime-closure.nix's existing shape (environment.systemPackages +
  every home-manager user's home.packages + hardware.graphics) with a short,
  explicit list of known NixOS-option-provided packages that never appear in
  any package list at all -- concretely, the compositor (programs.hyprland.*
  package options).

  A full recursive config-tree walk using builtins.getContext (to discover
  ALL such option-provided packages generically, not just hand-listed ones)
  was attempted and abandoned: it walks straight into nixpkgs' own
  mkIf-guarded laziness contract -- e.g. config.assertions.*.message strings
  assume they're only ever forced once their assertion is already known
  false (nixos/modules/tasks/filesystems.nix's cycle-detection assertion
  interpolates `fileSystems'.cycle`, which genuinely doesn't exist unless a
  real cycle was found) -- and each fix surfaced a structurally different new
  instance of the same problem rather than converging. Since this whole tier
  is explicitly a backup heuristic, not the source of truth, the pragmatic
  fix is scope, not more general robustness: hand-list the specific known
  gaps rather than chase the general case.

  Splice note: this only computes the HOST splice. o3-overlay.nix and
  gentoo-lto-overlay.nix both guard their entire body on
  `hostPlatform.gcc.arch` being present and return {} otherwise -- meaning
  isHostRuntime is never actually consulted for any non-host splice in this
  repo's real usage, so there is nothing to gain from computing one.
*/
{
  host,
  flakeRoot ? ../../../..,
}:
let
  flake = builtins.getFlake (toString flakeRoot);
  inherit (flake) inputs;
  lib = inputs.nixpkgs.lib;

  # Packages that only ever run on a builder, never on this host -- a deny
  # list applied AFTER the closure walk. Fail-open by design (see
  # runtime-closure.nix's original rationale, carried over verbatim): the
  # classifier can't prove runtime-unreachability for everything, so an
  # unlisted build-only tool just gets needlessly tuned (harmless, wastes
  # some build time); an over-eager listing here would silently drop a real
  # runtime dependency from tuning instead, which is the failure direction
  # that actually causes bugs (mesa/wlroots went untuned this way before).
  buildOnly = [
    "ccache"
    "mold"
    "mold-unwrapped-wrapper"
    "autoconf"
    "automake"
    "libtool"
    "cmake"
    "meson"
    "ninja"
    "pkg-config"
    "bison"
    "flex"
    "gperf"
    "help2man"
    "texinfo"
  ];

  pass1 = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostName = host;
    };
    modules = [
      inputs.home-manager.nixosModules.home-manager
      (flakeRoot + "/hosts/${host}")
      { nixpkgs.overlays = lib.mkForce [ ]; }
    ];
  };
  cfg = pass1.config;

  homePackages = lib.concatMap (u: u.home.packages or [ ]) (
    lib.attrValues (cfg.home-manager.users or { })
  );

  graphics =
    (cfg.hardware.graphics.extraPackages or [ ])
    ++ lib.optional ((cfg.hardware.graphics.package or null) != null) cfg.hardware.graphics.package;

  compositorPackages =
    lib.optional ((cfg.programs.hyprland.package or null) != null) cfg.programs.hyprland.package
    ++ lib.optional ((cfg.programs.hyprland.portalPackage or null) != null) cfg.programs.hyprland.portalPackage;

  anchors = lib.filter (p: p != null && (p ? pname || p ? name)) (
    cfg.environment.systemPackages ++ homePackages ++ graphics ++ compositorPackages
  );

  keyOf = p: p.pname or p.name or "unknown";

  closure = builtins.genericClosure {
    startSet = map (p: {
      key = keyOf p;
      pkg = p;
    }) anchors;
    operator =
      { pkg, ... }:
      map (p: {
        key = keyOf p;
        pkg = p;
      }) (
        lib.filter (p: p != null && (p ? pname || p ? name)) (
          (pkg.buildInputs or [ ]) ++ (pkg.propagatedBuildInputs or [ ])
        )
      );
  };

  runtimeNames = lib.unique (map (i: i.key) closure);
  candidates = lib.filter (n: !(builtins.elem n buildOnly)) runtimeNames;
in
{
  nixpkgsNarHash = flake.inputs.nixpkgs.narHash;
  nixpkgsRev = flake.inputs.nixpkgs.rev;
  inherit host;
  anchorCount = builtins.length anchors;
  inherit runtimeNames candidates buildOnly;
}
