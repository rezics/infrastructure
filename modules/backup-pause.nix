{
  config,
  lib,
  pkgs,
  ...
}:
let
  pause = pkgs.writeShellApplication {
    name = "pause-rezics-backups";
    runtimeInputs = [
      pkgs.docker
      pkgs.coreutils
    ];
    text = builtins.readFile ../scripts/pause-rezics-backups.sh;
  };
in
{
  options.services.rezicsBackupPause.enable = lib.mkEnableOption "persistently pause the retired REZICS backup schedules";
  config = lib.mkIf config.services.rezicsBackupPause.enable {
    environment.systemPackages = [ pause ];
    systemd.services.pause-rezics-backups = {
      description = "Keep the retired REZICS backup and verification schedules paused";
      wantedBy = [ "multi-user.target" ];
      after = [
        "docker.service"
        "nomad.service"
      ];
      requires = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pause}/bin/pause-rezics-backups";
        TimeoutStartSec = "3min";
      };
    };
  };
}
