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

      Turning this on sets environment.ldso, which is a system-wide change;
      the reason is below and it is not incidental
    '';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ claude-science ];

    /*
      Why a system-wide loader, and why NOT nix-ld.

      Claude Science does not ship its science tooling. The daemon downloads
      micromamba into ~/.claude-science at runtime and has it build a conda
      environment per bundled MCP connector -- genomes, chemistry, literature,
      some twenty of them -- plus the `python` and `r` analysis environments.
      Those are generic-linux ELFs created after the build, living in $HOME.
      There is no derivation to autoPatchelf and no store path to fix up: they
      ask the kernel for /lib64/ld-linux-x86-64.so.2, and stock NixOS answers
      with stub-ld, whose entire job is to print "NixOS cannot run dynamically
      linked executables".

      nix-ld is the usual answer to that and it was tried first. It does not
      work here, and the reason is structural rather than a missing library.
      nix-ld's contract is the NIX_LD environment variable, falling back to
      /run/current-system/sw/share/nix-ld/lib/ld.so. The daemon runs those
      binaries inside its own bubblewrap sandbox, which binds /nix but NOT
      /run, and it hands children a curated environment that does not carry
      NIX_LD. Both halves of the contract are therefore absent exactly where
      the loader is needed, and every conda build died with

        [nix-ld] FATAL: panicked at src/main.rs:187:55:
        called `Result::unwrap()` on an `Err` value: Posix(2)   (ENOENT)

      Measured, not inferred: the daemon's own /proc/<pid>/environ showed
      NIX_LD set to a store path while its sandboxed child still failed, and
      reproducing the namespace by hand (bwrap with /nix and /lib64 bound and
      no /run) gave micromamba 2.5.0 with NIX_LD set and that same panic with
      it unset. So no setting of NIX_LD, at any scope, can reach the process
      that needs it.

      Pointing /lib64/ld-linux-x86-64.so.2 at glibc's real loader removes the
      environment from the equation entirely, which is the property that
      matters: it works in a namespace with no /run and no inherited env.
      environment.ldso is the same option programs.nix-ld sets, so the two are
      alternatives, not companions -- do not enable nix-ld alongside this.

      The cost is nix-ld's library injection, which this app does not need:
      conda environments are self-contained and carry their own libstdc++,
      zlib and openssl with RPATHs to match, and micromamba's whole NEEDED set
      is glibc.
    */
    environment.ldso = "${pkgs.glibc}/lib/ld-linux-x86-64.so.2";
  };
}
