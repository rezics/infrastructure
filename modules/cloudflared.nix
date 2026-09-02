{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.cloudflaredTunnel;
in
{
  options.services.cloudflaredTunnel = {
    enable = lib.mkEnableOption "remotely managed Cloudflare Tunnel";
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime file containing the remotely managed tunnel token.";
    };
    credentialProvisioningUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Systemd units that must finish before the tunnel token is available.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.cloudflared-tunnel = {
      description = "Cloudflare Tunnel";
      after = [ "network-online.target" ] ++ cfg.credentialProvisioningUnits;
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate --loglevel info run --token-file %d/tunnel_token";
        LoadCredential = "tunnel_token:${cfg.tokenFile}";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };
  };
}
