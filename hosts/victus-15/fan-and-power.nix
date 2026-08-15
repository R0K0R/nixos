{ config, pkgs, ... }:

{
  # HP Victus 15 fan curve fix — stock EC fan control is stuck/insufficient under load.
  systemd.services.nbfc_service = {
    enable = true;
    description = "NoteBook FanControl service";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" "systemd-modules-load.service" ];
    path = [ pkgs.kmod ];
    serviceConfig = {
      Type = "simple";
      ExecStartPre = "${pkgs.nbfc-linux}/bin/nbfc wait-for-hwmon";
      ExecStart = "${pkgs.nbfc-linux}/bin/nbfc_service --config-file '/etc/nbfc/nbfc.json'";
    };
  };

  environment.etc."nbfc/nbfc.json".text = ''
    {
      "SelectedConfigId": "HP Victus 15-fb0xxx"
    }
  '';

  # Ryzen power limits — raise from the conservative stock STAPM/fast/slow limits.
  boot.extraModulePackages = [ config.boot.kernelPackages.ryzen-smu ];
  boot.kernelModules = [ "ryzen_smu" ];

  systemd.services.ryzenadj = {
    description = "RyzenAdj Power Settings";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.ryzenadj}/bin/ryzenadj --tctl-temp=95 --stapm-limit=65000 --fast-limit=65000 --slow-limit=65000 --apu-slow-limit=65000 --apu-skin-temp=95 --dgpu-skin-temp=95";
      RemainAfterExit = true;
    };
  };
}
