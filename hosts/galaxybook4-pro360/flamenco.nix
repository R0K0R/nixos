{ lib, pkgs, ... }:

let
  flamenco = pkgs.stdenv.mkDerivation {
    pname = "flamenco";
    version = "3.9.2";
    src = pkgs.fetchurl {
      url = "https://flamenco.blender.org/downloads/flamenco-3.9.2-linux-amd64.tar.gz";
      hash = "sha256-tuVpX8ikAw1a7lFlIjAE7SWQJweuWBdLcN0EoH7QJFI=";
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.libc ];
    sourceRoot = "flamenco-3.9.2-linux-amd64";
    installPhase = ''
      install -Dm755 flamenco-manager $out/bin/flamenco-manager
    '';
    meta.platforms = [ "x86_64-linux" ];
  };
in
{
  users.users.flamenco = {
    isSystemUser = true;
    group = "flamenco";
    home = "/var/lib/flamenco-manager";
    createHome = true;
  };
  users.groups.flamenco = { };

  environment.systemPackages = [ flamenco ];

  # First-run: sudo -u flamenco flamenco-manager (from /var/lib/flamenco-manager)
  # It will write flamenco-manager.yaml, then start this service.
  systemd.services.flamenco-manager = {
    description = "Flamenco render farm manager";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    # Don't start until the config file exists (written by first-run wizard).
    unitConfig.ConditionPathExists = "/var/lib/flamenco-manager/flamenco-manager.yaml";
    serviceConfig = {
      ExecStart = "${flamenco}/bin/flamenco-manager";
      WorkingDirectory = "/var/lib/flamenco-manager";
      User = "flamenco";
      Group = "flamenco";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
