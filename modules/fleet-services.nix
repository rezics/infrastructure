{
  config,
  lib,
  pkgs,
  ...
}:
let
  nomad = config.services.nomad.package;
  reconcile = pkgs.writeShellApplication {
    name = "reconcile-fleet-services";
    runtimeInputs = [
      nomad
      pkgs.coreutils
    ];
    text = builtins.readFile ../scripts/reconcile-fleet-services.sh;
  };
  backup = pkgs.writeShellApplication {
    name = "run-databasus-control-backup";
    runtimeInputs = [
      nomad
      pkgs.coreutils
      pkgs.jq
    ];
    text = builtins.readFile ../scripts/run-databasus-control-backup.sh;
  };
  operator = pkgs.writeShellApplication {
    name = "rezics-nomad-operator";
    runtimeInputs = [ nomad ];
    text = ''
      export NOMAD_ADDR=https://127.0.0.1:4646
      export NOMAD_TLS_SERVER_NAME=server.global.nomad
      export NOMAD_CACERT=/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem
      export NOMAD_CLIENT_CERT=/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem
      export NOMAD_CLIENT_KEY=/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem
      NOMAD_TOKEN="$(</root/.config/nomad/management.token)"
      export NOMAD_TOKEN
      exec nomad "$@"
    '';
  };
  credentials = [
    "management-token:/root/.config/nomad/management.token"
    "nomad-ca:/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
    "nomad-client-cert:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
    "nomad-client-key:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
  ];
  environment = [
    "NOMAD_CACERT=%d/nomad-ca"
    "NOMAD_CLIENT_CERT=%d/nomad-client-cert"
    "NOMAD_CLIENT_KEY=%d/nomad-client-key"
  ];
in
{
  options.services.rezicsRetainedPlatform.enable = lib.mkEnableOption "Outline and PostgreSQL backup control plane without the retired application";
  config = lib.mkIf config.services.rezicsRetainedPlatform.enable {
    users.groups.rezics-deploy.gid = 989;
    users.users.rezics-deploy = {
      isSystemUser = true;
      uid = 992;
      group = "rezics-deploy";
      home = "/var/lib/rezics-deploy";
    };
    users.groups.rezics-infrastructure-deploy = { };
    users.users.rezics-infrastructure-deploy = {
      isSystemUser = true;
      group = "rezics-infrastructure-deploy";
      home = "/var/lib/rezics-infrastructure-deploy";
    };
    environment.systemPackages = [
      operator
      reconcile
      backup
    ];
    environment.etc = {
      "fleet-services/outline-app.nomad.hcl".source = ../jobs/edge/outline/outline-app.nomad.hcl;
      "fleet-services/outline-postgres.nomad.hcl".source =
        ../jobs/data/outline/outline-postgres.nomad.hcl;
      "fleet-services/databasus.nomad.hcl".source = ../jobs/data/backup/databasus.nomad.hcl;
      "fleet-services/databasus-verification-agent.nomad.hcl".source =
        ../jobs/data/backup/databasus-verification-agent.nomad.hcl;
      "fleet-services/databasus-control-backup.nomad.hcl".source =
        ../jobs/data/backup/databasus-control-backup.nomad.hcl;
    };
    # Outline restore verification still uses the retained PostgreSQL images.
    services.dockerRegistry = {
      enable = true;
      listenAddress = "10.64.0.1";
      port = 5000;
      openFirewall = false;
      enableDelete = true;
      enableGarbageCollect = true;
      garbageCollectDates = "weekly";
      storagePath = "/var/lib/rezics-registry";
    };
    services.traefik = {
      enable = true;
      environmentFiles = [ "/var/lib/traefik/nomad.env" ];
      staticConfigOptions = {
        entryPoints.web.address = "127.0.0.1:8080";
        api.dashboard = false;
        log = {
          level = "INFO";
          format = "json";
        };
        accessLog = {
          format = "json";
          bufferingSize = 100;
        };
        providers.nomad = {
          namespaces = [
            "default"
            "rezics-infrastructure"
          ];
          exposedByDefault = false;
          watch = true;
          endpoint = {
            address = "https://127.0.0.1:4646";
            tls = {
              ca = "/var/lib/traefik/nomad-tls/nomad-agent-ca.pem";
              cert = "/var/lib/traefik/nomad-tls/global-cli-nomad.pem";
              key = "/var/lib/traefik/nomad-tls/global-cli-nomad-key.pem";
              insecureSkipVerify = false;
            };
          };
        };
      };
    };
    systemd.services.traefik = {
      after = [ "nomad.service" ];
      wants = [ "nomad.service" ];
    };
    systemd.services.fleet-services-reconcile = {
      description = "Retire legacy jobs and reconcile Outline and PostgreSQL backups";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nomad.service"
      ];
      requires = [ "nomad.service" ];
      # UID 989 belonged solely to the retired rootless release builder.
      preStart = ''
        ${pkgs.systemd}/bin/loginctl terminate-user 989 || true
      '';
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${reconcile}/bin/reconcile-fleet-services";
        LoadCredential = credentials;
        Environment = environment ++ [ "FLEET_NOMAD_MANAGEMENT_TOKEN_FILE=%d/management-token" ];
        TimeoutStartSec = "5min";
        UMask = "0077";
      };
    };
    systemd.services.rezics-databasus-control-backup = {
      description = "Cold encrypted backup of the Databasus control database";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "nomad.service"
        "fleet-services-reconcile.service"
      ];
      requires = [ "nomad.service" ];
      environment.REZICS_DATABASUS_CONTROL_BACKUP_JOB_FILE = "/etc/fleet-services/databasus-control-backup.nomad.hcl";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backup}/bin/run-databasus-control-backup";
        LoadCredential = credentials;
        Environment = environment ++ [ "REZICS_NOMAD_MANAGEMENT_TOKEN_FILE=%d/management-token" ];
        TimeoutStartSec = "30m";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "strict";
      };
    };
    systemd.timers.rezics-databasus-control-backup = {
      description = "Daily Databasus control-database backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 04:30:00 UTC";
        Persistent = true;
        RandomizedDelaySec = "10m";
        Unit = "rezics-databasus-control-backup.service";
      };
    };
  };
}
