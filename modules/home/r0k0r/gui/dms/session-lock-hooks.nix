{ config, lib, ... }:

let
  dmsExe = lib.getExe config.programs.dank-material-shell.package;
  lockCmd = "${dmsExe} ipc lock lock";
  dmst = config.programs.dank-material-shell.systemd.target;
in
{
  systemd.user.services = lib.mkIf config.programs.dank-material-shell.enable {
    dms-lock-on-logind-lock = {
      Unit = {
        Description = "DMS lock when logind activates lock.target";
        PartOf = [ "lock.target" ];
        Before = [ "lock.target" ];
      };
      Install.WantedBy = [ "lock.target" ];
      Service = {
        Type = "oneshot";
        ExecStart = lockCmd;
        RemainAfterExit = true;
      };
    };

    dms-lock-before-suspend = {
      Unit = {
        Description = "DMS lock before user suspend (lid close etc.)";
        PartOf = [ "sleep.target" ];
        Before = [ "sleep.target" ];
        After = [ dmst ];
      };
      Install.WantedBy = [ "sleep.target" ];
      Service = {
        Type = "oneshot";
        ExecStart = lockCmd;
        RemainAfterExit = true;
      };
    };
  };
}
