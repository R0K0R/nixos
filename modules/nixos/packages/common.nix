{ pkgs, ... }:

with pkgs; [
  wget
  openvpn
  upower

  # npm-managed claude-code: stays current with upstream releases, unlike the
  # plain nixpkgs package which lags. Shared by every host (galaxybook4-pro360,
  # victus-15) rather than duplicated per-host. The actual `npm install -g`
  # step runs via a home-manager activation hook
  # (modules/home/r0k0r/cli/claude-code.nix) for users that have a home-manager
  # profile, or a NixOS system.activationScripts hook for hosts that don't.
  (buildFHSEnv {
    name = "claude";
    targetPkgs = p: [ p.nodejs p.glibc p.stdenv.cc.cc.lib ];
    runScript = writeScript "run-claude" ''
      #!/bin/sh
      exec "$HOME/.npm-global/bin/claude" "$@"
    '';
  })
]
