{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.claude-science;

  # Hash-pinned via the claude-science-bin flake input.
  # Bump: features/claude-science/update.sh.
  claude-science = pkgs.callPackage ./package.nix {
    src = inputs.feat-claude-science.src;
    version = inputs.feat-claude-science.version;
  };
in
{
  options.my.claude-science = {
    enable = lib.mkEnableOption ''
      Claude Science (beta), Anthropic's local research app.

      `claude-science serve` starts a daemon on 127.0.0.1:8000 and opens the web
      UI in a browser; `--detached` backgrounds it, `--no-browser` skips the
      browser. State lives in ~/.claude-science, not in the store.

      Note that `claude-science update` -- its self-updater -- cannot work here:
      it rewrites its own executable, which is a read-only store path. That is
      not a defect to work around, it is the pin doing its job. Use
      features/claude-science/update.sh instead.

      Turning this on turns on programs.nix-ld, which is a system-wide change;
      the reason is below and it is not incidental
    '';

    nix-ld.extraLibraries = lib.mkOption {
      type = lib.types.functionTo (lib.types.listOf lib.types.package);
      default = _: [ ];
      defaultText = lib.literalExpression "pkgs: [ ]";
      example = lib.literalExpression "pkgs: [ pkgs.libGL ]";
      description = ''
        Extra libraries to put on NIX_LD_LIBRARY_PATH for the foreign binaries
        the daemon downloads, appended to the set below.

        Escape hatch, and expected to be used: the conda packages a connector
        pulls are not knowable from here, and a missing .so surfaces as a
        connector that just fails to start.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ claude-science ];

    /*
      Why a system-wide loader shim for one app.

      Claude Science does not ship its science tooling. The daemon downloads
      micromamba into ~/.claude-science at runtime and has it build conda
      environments for each bundled MCP connector -- genomes, chemistry,
      literature, some twenty of them. Those are generic-linux ELFs, created
      after the build, living in $HOME. There is no derivation to autoPatchelf
      and no store path to fix up: they ask the kernel for
      /lib64/ld-linux-x86-64.so.2 and NixOS answers with stub-ld, whose entire
      job is to print "NixOS cannot run dynamically linked executables".

      Measured on this machine before nix-ld: every connector failed with
      "Could not start dynamically linked executable:
      ~/.claude-science/conda/bin/micromamba", and that same micromamba ran
      correctly the moment a real loader was reachable -- its NEEDED set is
      glibc and nothing else.

      nix-ld is the mechanism for precisely this shape of program, and it is
      also what lets the app's OWN binary run unmodified, which the Bun
      single-file format requires (see ./package.nix). So this is not a
      convenience: without it the package is a web UI with no tools, and
      `serve --detached` does not start at all.
    */
    programs.nix-ld = {
      enable = true;
      libraries =
        with pkgs;
        [
          # glibc is implicit in nix-ld's own default set; these are what conda
          # binaries and CPython extension modules reach for beyond it.
          stdenv.cc.cc.lib # libstdc++, for compiled wheels
          zlib
          openssl
          bzip2
          xz
          libffi # _ctypes
          ncurses
          readline
          sqlite # _sqlite3
        ]
        ++ cfg.nix-ld.extraLibraries pkgs;
    };
  };
}
