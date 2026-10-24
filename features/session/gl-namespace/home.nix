/*
  my.graphics.driver in a HOME: this user's own graphics driver tree, for
  hosts with my.gl-namespace (the nixos half explains the mechanism).

  WHEN. Only when the home's package set is not the system's (my.tuning):
  the driver is loaded into every GL program, so it must come from the same
  set as the programs. On the host's own set the tree would be the system's
  derivation anyway.

  WHAT. A buildEnv of `packages` from THIS home's pkgs, named like the
  system's ("graphics-drivers"), linked into the generation as
  $generation/graphics-driver (and -32). The system's gl-driver-select reads
  that link from the user's current generation at login and on every
  home-manager switch; the generation is what keeps the tree alive, and a
  rollback rolls the driver back with everything else.

  DEFAULT PACKAGES: the system's hardware.graphics package + extraPackages,
  looked up by pname in this home's set. Ones that are not top-level
  attributes (nvidia-x11 lives under linuxPackages and must match the
  running kernel module) are left out with a warning -- on an NVIDIA host
  keep the system's driver, it is the epoch member there anyway.

  32-bit: `packages32` is empty by default, so 32-bit programs keep the
  system's 32-bit tree (on a march host this home's set has no usable
  pkgsi686Linux).

  homeLib's surface check (lib/surface-check.nix) treats a home with this on
  differently: the system's driver is no longer loaded into its programs, but
  this tree is loaded into the system programs run in its sessions (the
  compositor, the system terminal), so it is checked against the system
  profile instead.
*/
{ config, lib, pkgs, osConfig ? null, ... }:

let
  cfg = config.my.graphics.driver;
  ns = if osConfig == null then { } else osConfig.my.gl-namespace or { };
  sysG = if osConfig == null then { enable = false; } else osConfig.hardware.graphics;
  user = config.home.username;
  mapped = (ns.active or false) && lib.elem user (ns.users or [ ]);

  sysPackages = lib.optionals (sysG.enable or false) ([ sysG.package ] ++ sysG.extraPackages);
  pnameOf = p: p.pname or (lib.getName p);
  resolved = map (p: {
    name = pnameOf p;
    pkg = let n = pnameOf p; in if pkgs ? ${n} && lib.isDerivation pkgs.${n} then pkgs.${n} else null;
  }) sysPackages;
  # System driver packages with no counterpart (by pname) in the tree.
  missing = lib.subtractLists (map pnameOf cfg.packages) (map (r: r.name) resolved);

  tree = pkgs.buildEnv {
    name = "graphics-drivers";
    paths = cfg.packages;
  };
  tree32 = pkgs.buildEnv {
    name = "graphics-drivers-32bit";
    paths = cfg.packages32;
  };
in
{
  options.my.graphics.driver = {
    enable = lib.mkEnableOption ''
      this home's own /run/opengl-driver tree, built from this home's package
      set (needs the host's my.gl-namespace with this account in its users)'';

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = lib.filter (p: p != null) (map (r: r.pkg) resolved);
      defaultText = lib.literalMD "the system's `hardware.graphics.package` + `extraPackages`, by pname, from this home's `pkgs`";
      description = "What goes into the tree: mesa and any VA-API/Vulkan/OpenCL drivers, from this home's `pkgs`.";
    };

    packages32 = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "The 32-bit tree. Empty: 32-bit programs keep the system's.";
    };

    tree = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = tree;
      description = "The buildEnv linked as $generation/graphics-driver.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = mapped;
        message = ''
          my.graphics.driver is on, but ${
            if !(ns.enable or false) then
              "this host has no my.gl-namespace"
            else if !(ns.active or false) then
              "this host's my.gl-namespace is not active (hardware.graphics off, or no users)"
            else
              "${user} is not in this host's my.gl-namespace.users"
          }.
          /run/opengl-driver in your sessions would stay the system's, and your
          programs would load a driver from a set they were not built against.
          Turn it off, or ask the admin to map you.'';
      }
      {
        assertion = cfg.packages != [ ];
        message = "my.graphics.driver.packages is empty: there would be no driver at all.";
      }
    ];
    warnings = lib.optional (missing != [ ]) ''
      my.graphics.driver: the system's graphics packages ${lib.concatStringsSep ", " missing}
      are NOT in your driver tree (no top-level attribute of that name in your package
      set, and not listed in my.graphics.driver.packages). Add them if you need them.'';

    home.extraBuilderCommands =
      ''
        ln -s ${tree} $out/graphics-driver
      ''
      + lib.optionalString (cfg.packages32 != [ ]) ''
        ln -s ${tree32} $out/graphics-driver-32
      '';
  };
}
