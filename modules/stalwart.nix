{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.rezicsMail;
  server = pkgs.callPackage ../packages/stalwart.nix { };
  cli = pkgs.callPackage ../packages/stalwart-cli.nix { };
  dataDir = "/var/lib/stalwart";
  datastore = pkgs.writeText "stalwart-config.json" (
    builtins.toJSON {
      "@type" = "RocksDb";
      path = "${dataDir}/db-v016";
    }
  );
  policy = pkgs.writeText "stalwart-policy.json" (
    builtins.toJSON {
      inherit (cfg) hostname domain forwarding;
      certificate = {
        certificate = {
          "@type" = "File";
          filePath = "/var/lib/acme/${cfg.hostname}/fullchain.pem";
        };
        privateKey = {
          "@type" = "File";
          filePath = "/var/lib/acme/${cfg.hostname}/key.pem";
        };
      };
      listeners = {
        smtp = {
          name = "smtp";
          protocol = "smtp";
          bind."0.0.0.0:25" = true;
        };
        submission = {
          name = "submission";
          protocol = "smtp";
          bind."0.0.0.0:587" = true;
        };
        submissions = {
          name = "submissions";
          protocol = "smtp";
          bind."0.0.0.0:465" = true;
          tlsImplicit = true;
        };
        imaps = {
          name = "imaps";
          protocol = "imap";
          bind."0.0.0.0:993" = true;
          tlsImplicit = true;
        };
        https = {
          name = "https";
          protocol = "http";
          bind."0.0.0.0:443" = true;
          tlsImplicit = true;
        };
        management = {
          name = "management";
          protocol = "http";
          bind."127.0.0.1:8085" = true;
          useTls = false;
        };
      };
    }
  );
  configure = pkgs.writeShellScript "configure-stalwart" ''
    exec ${pkgs.python3}/bin/python3 ${../scripts/configure-stalwart.py} \
      --policy ${policy} --config ${datastore} \
      --server ${server}/bin/stalwart --cli ${cli}/bin/stalwart-cli
  '';
  start = pkgs.writeShellScript "start-stalwart" ''
    export STALWART_RECOVERY_ADMIN="admin:$(cat "$CREDENTIALS_DIRECTORY/admin")"
    exec ${server}/bin/stalwart --config ${datastore}
  '';
  backup = pkgs.writeShellApplication {
    name = "backup-stalwart";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.restic
      pkgs.systemd
    ];
    text = builtins.readFile ../scripts/backup-stalwart.sh;
  };
in
{
  options.services.rezicsMail = {
    enable = lib.mkEnableOption "the single-node Stalwart mail service";
    backup = {
      enable = lib.mkEnableOption "daily encrypted off-host Stalwart backups";
      environmentFile = lib.mkOption {
        type = lib.types.str;
        description = "Runtime-only Restic and S3 environment file.";
      };
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
      };
    };
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "Public mail hostname.";
    };
    contactEmail = lib.mkOption {
      type = lib.types.str;
      description = "ACME account contact.";
    };
    adminPasswordHashFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime-only admin password hash file.";
    };
    initialProvisioningFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime-only initial mailbox credential and DKIM key material.";
    };
    domain = lib.mkOption { type = lib.types.str; };
    forwarding = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options.address = lib.mkOption { type = lib.types.str; };
          options.destinations = lib.mkOption { type = lib.types.listOf lib.types.str; };
        }
      );
      default = [ ];
    };
    publicInterface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
    };
  };
  config = lib.mkIf cfg.enable {
    users.groups.stalwart = { };
    users.users.stalwart = {
      isSystemUser = true;
      group = "stalwart";
      home = dataDir;
    };
    environment.systemPackages = [
      server
      cli
    ];
    security.acme = {
      acceptTerms = true;
      defaults.email = cfg.contactEmail;
      certs."${cfg.hostname}" = {
        listenHTTP = ":80";
        group = "stalwart";
        reloadServices = [ "stalwart" ];
      };
    };
    systemd.services.stalwart = {
      description = "Stalwart mail server";
      wantedBy = [ "multi-user.target" ];
      wants = [ "acme-${cfg.hostname}.service" ];
      after = [ "acme-${cfg.hostname}.service" ];
      environment.STALWART_HOSTNAME = cfg.hostname;
      serviceConfig = {
        User = "stalwart";
        Group = "stalwart";
        StateDirectory = "stalwart";
        StateDirectoryMode = "0700";
        LoadCredential = [
          "admin:${cfg.adminPasswordHashFile}"
          "initial:${cfg.initialProvisioningFile}"
        ];
        ExecStartPre = configure;
        ExecStart = start;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        Restart = "on-failure";
        TimeoutStartSec = "5min";
        UMask = "0077";
        MemoryMax = "2G";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };
    systemd.services.stalwart-backup = lib.mkIf cfg.backup.enable {
      description = "Encrypted Stalwart recovery set with restore verification";
      environment = {
        STALWART_DATA_DIR = dataDir;
        STALWART_ADMIN_HASH_FILE = cfg.adminPasswordHashFile;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backup}/bin/backup-stalwart";
        EnvironmentFile = cfg.backup.environmentFile;
        TimeoutStartSec = "10min";
        MemoryMax = "1G";
        UMask = "0077";
        StateDirectory = "stalwart-backup";
        StateDirectoryMode = "0700";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/stalwart-backup" ];
      };
    };
    systemd.timers.stalwart-backup = lib.mkIf cfg.backup.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.backup.schedule;
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    };
    networking.firewall.interfaces."${cfg.publicInterface}".allowedTCPPorts = [
      25
      80
      443
      465
      587
      993
    ];
  };
}
