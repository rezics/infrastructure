{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.rezicsPlatform;
  nomadPackage = config.services.nomad.package;
  fleet = config.services.rezicsFleet;
  releaseGateway = pkgs.callPackage ../packages/release-gateway.nix { };
  credentialFileOption =
    description:
    lib.mkOption {
      type = lib.types.str;
      inherit description;
    };
  releaseSkopeoPolicy = pkgs.writeText "rezics-release-skopeo-policy.json" (
    builtins.toJSON {
      default = [ { type = "reject"; } ];
      transports."docker-archive"."" = [
        { type = "insecureAcceptAnything"; }
      ];
    }
  );
  nomadEnvironment = owner: ''
    export NOMAD_ADDR=https://127.0.0.1:4646
    export NOMAD_CACERT=/var/lib/${owner}/nomad-tls/nomad-agent-ca.pem
    export NOMAD_CLIENT_CERT=/var/lib/${owner}/nomad-tls/global-cli-nomad.pem
    export NOMAD_CLIENT_KEY=/var/lib/${owner}/nomad-tls/global-cli-nomad-key.pem
    export NOMAD_NAMESPACE=rezics
    export NOMAD_TLS_SERVER_NAME=server.global.nomad
  '';
  rezicsNomad = pkgs.writeShellApplication {
    name = "rezics-nomad";
    runtimeInputs = [ nomadPackage ];
    text = ''
      if [[ -z "''${NOMAD_TOKEN:-}" ]]; then
        token_file=/var/lib/rezics-deploy/nomad.token
        if [[ ! -r "$token_file" ]]; then
          printf '%s\n' "Nomad deploy token is not installed" >&2
          exit 1
        fi
        NOMAD_TOKEN="$(<"$token_file")"
      fi
      ${nomadEnvironment "rezics-deploy"}
      export NOMAD_TOKEN
      exec nomad "$@"
    '';
  };
  rezicsNomadOperator = pkgs.writeShellApplication {
    name = "rezics-nomad-operator";
    runtimeInputs = [ nomadPackage ];
    text = ''
      token_file=/root/.config/nomad/management.token
      if [[ "$(id -u)" != 0 || ! -r "$token_file" ]]; then
        printf '%s\n' "rezics-nomad-operator requires the root management token" >&2
        exit 1
      fi
      ${nomadEnvironment "rezics-deploy"}
      NOMAD_TOKEN="$(<"$token_file")"
      export NOMAD_TOKEN
      exec nomad "$@"
    '';
  };
  rezicsNomadInfrastructure = pkgs.writeShellApplication {
    name = "rezics-nomad-infrastructure";
    runtimeInputs = [ nomadPackage ];
    text = ''
      token_file=/var/lib/rezics-infrastructure-deploy/nomad.token
      if [[ ! -r "$token_file" ]]; then
        printf '%s\n' "Nomad infrastructure token is not installed" >&2
        exit 1
      fi
      ${nomadEnvironment "rezics-infrastructure-deploy"}
      NOMAD_TOKEN="$(<"$token_file")"
      export NOMAD_TOKEN
      exec nomad "$@"
    '';
  };
  runRezicsMaintenanceResponse = pkgs.writeShellApplication {
    name = "run-rezics-maintenance-response";
    text = builtins.readFile ../scripts/run-rezics-maintenance-response.sh;
  };
  runRezicsMaintenanceServer = pkgs.writeShellApplication {
    name = "run-rezics-maintenance-server";
    runtimeInputs = [ pkgs.socat ];
    text = builtins.readFile ../scripts/run-rezics-maintenance-server.sh;
  };
  runRezicsReleaseMaintenance = pkgs.writeShellApplication {
    name = "run-rezics-release-maintenance";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      rezicsNomad
    ];
    text = builtins.readFile ../scripts/run-rezics-release-maintenance.sh;
  };
  runRezicsReleaseBuild = pkgs.writeShellApplication {
    name = "run-rezics-release-build";
    runtimeInputs = [
      pkgs.acl
      pkgs.coreutils
      pkgs.docker
      pkgs.findutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
    ];
    text = builtins.readFile ../scripts/run-rezics-release-build.sh;
  };
  runRezicsServiceDeploy = pkgs.writeShellApplication {
    name = "run-rezics-service-deploy";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnused
      pkgs.jq
      rezicsNomad
    ];
    text = builtins.readFile ../scripts/run-rezics-service-deploy.sh;
  };
  runRezicsRelease = pkgs.writeShellApplication {
    name = "run-rezics-release";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.gawk
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.skopeo
      pkgs.util-linux
      nomadPackage
      rezicsNomad
    ];
    text = ''
      export REZICS_SKOPEO_POLICY=${releaseSkopeoPolicy}
      ${builtins.readFile ../scripts/run-rezics-release.sh}
    '';
  };
  reconcileRezicsDelivery = pkgs.writeShellApplication {
    name = "reconcile-rezics-delivery";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      nomadPackage
    ];
    text = builtins.readFile ../scripts/reconcile-rezics-delivery.sh;
  };
  reconcileRezicsPlatform = pkgs.writeShellApplication {
    name = "reconcile-rezics-platform";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      nomadPackage
    ];
    text = builtins.readFile ../scripts/reconcile-rezics-platform.sh;
  };
  reconcileRezicsDatabase = pkgs.writeShellApplication {
    name = "reconcile-rezics-database";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.postgresql_18
      nomadPackage
    ];
    text = builtins.readFile ../scripts/reconcile-rezics-database.sh;
  };
  signozDashboardRevision = "a8df581196ad00fb28e932e5594772cb82157f68";
  signozDashboards = [
    (pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/SigNoz/dashboards/${signozDashboardRevision}/hostmetrics/hostmetrics.json";
      hash = "sha256-aNzPocOTzZsXihRdece3TysThgUlTwwo6TYH+x4cW4I=";
    })
    (pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/SigNoz/dashboards/${signozDashboardRevision}/container-metrics/docker/container-metrics-by-host.json";
      hash = "sha256-63x+A92QeB8qm//OMAOhqsW8xaU+hVhPE4r2imLeg18=";
    })
    (pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/SigNoz/dashboards/${signozDashboardRevision}/nomad/nomad-metrics-by-host.json";
      hash = "sha256-lTzsojHUOzZXpRI9OBOCinml98h7ia4mD1/oFMzZ2hk=";
    })
    (pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/SigNoz/dashboards/${signozDashboardRevision}/postgresql/postgresql.json";
      hash = "sha256-F+LrO7Yyc5L0aGHemI4X5D3aO8pKjvkXB74Iq3zR8fw=";
    })
    (pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/SigNoz/dashboards/${signozDashboardRevision}/apm/apm-metrics.json";
      hash = "sha256-RWRsoE95GUaaF4bTET0YFwteXpDfaect+24P+e730d8=";
    })
    (pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/SigNoz/dashboards/${signozDashboardRevision}/apm/http-api-monitoring.json";
      hash = "sha256-1IpJk0qa7F9ba3ihOooa+vKv7S2jvcCaERXbdti3gWw=";
    })
    (pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/SigNoz/dashboards/${signozDashboardRevision}/apm/db-calls-monitoring.json";
      hash = "sha256-GF2KD/otdbqsgqnYGbzd1zvX3F04Xs2R0UP7sANpQMU=";
    })
    (pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/SigNoz/dashboards/${signozDashboardRevision}/signoz-ingestion-analysis/signoz-ingestion-analysis-v2.json";
      hash = "sha256-NnYqziPUqzPC7SJBvYQb4Rl0b/BDhQgPk3+1R1zaXFw=";
    })
  ];
  provisionSignoz = pkgs.writeShellApplication {
    name = "provision-rezics-signoz";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = builtins.readFile ../scripts/provision-signoz.sh;
  };
  runDatabasusControlBackup = pkgs.writeShellApplication {
    name = "run-databasus-control-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      nomadPackage
    ];
    text = builtins.readFile ../scripts/run-databasus-control-backup.sh;
  };
  gatewayStart = pkgs.writeShellScript "start-rezics-release-gateway" ''
    export NOMAD_ADDR=https://127.0.0.1:4646
    export NOMAD_CACERT="$CREDENTIALS_DIRECTORY/nomad-ca"
    export NOMAD_CLIENT_CERT="$CREDENTIALS_DIRECTORY/nomad-client-cert"
    export NOMAD_CLIENT_KEY="$CREDENTIALS_DIRECTORY/nomad-client-key"
    export NOMAD_TLS_SERVER_NAME=server.global.nomad
    export REZICS_NOMAD_ADMIN_USERNAME_FILE="$CREDENTIALS_DIRECTORY/admin-username"
    export REZICS_NOMAD_ADMIN_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/admin-password"
    export REZICS_NOMAD_ADMIN_TOKEN_FILE="$CREDENTIALS_DIRECTORY/admin-token"
    exec ${releaseGateway}/bin/release-gateway
  '';
in
{
  options.services.rezicsPlatform = {
    credentialFiles = {
      releaseGatewayAdminUsername = credentialFileOption "Runtime file containing the release gateway administrator username.";
      releaseGatewayAdminPassword = credentialFileOption "Runtime file containing the release gateway administrator password.";
      releaseGatewayNomadToken = credentialFileOption "Runtime file containing the release gateway Nomad token.";
      signozTokenizerJwtSecret = credentialFileOption "Runtime file containing the SigNoz tokenizer JWT secret.";
      signozRootEmail = credentialFileOption "Runtime file containing the SigNoz root account email.";
      signozRootPassword = credentialFileOption "Runtime file containing the SigNoz root account password.";
      signozRootOrgName = credentialFileOption "Runtime file containing the SigNoz root organization name.";
      signozRootOrgId = credentialFileOption "Runtime file containing the SigNoz root organization identifier.";
    };
    credentialProvisioningUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Systemd units that must finish before runtime credential files are available.";
    };
  };

  config = {
    users.groups.rezics-ci = { };
    users.users.rezics-ci = {
      uid = 989;
      isSystemUser = true;
      group = "rezics-ci";
      home = "/var/lib/rezics-ci";
      createHome = true;
      homeMode = "0700";
      linger = true;
      subUidRanges = [
        {
          startUid = 200000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 200000;
          count = 65536;
        }
      ];
    };

    users.groups.rezics-deploy.gid = 989;
    users.users.rezics-deploy = {
      isSystemUser = true;
      uid = 992;
      group = "rezics-deploy";
      home = "/var/lib/rezics-deploy";
      createHome = true;
    };
    users.groups.rezics-infrastructure-deploy = { };
    users.users.rezics-infrastructure-deploy = {
      isSystemUser = true;
      group = "rezics-infrastructure-deploy";
      home = "/var/lib/rezics-infrastructure-deploy";
      createHome = true;
    };

    virtualisation.docker.rootless = {
      enable = true;
      setSocketVariable = false;
      extraPackages = [
        pkgs.fuse-overlayfs
        pkgs.slirp4netns
      ];
      daemon.settings = {
        "data-root" = "/var/lib/rezics-ci/docker";
        "log-driver" = "local";
        "no-new-privileges" = true;
        "storage-driver" = "fuse-overlayfs";
      };
    };

    services.dockerRegistry = {
      enable = true;
      listenAddress = fleet.wireguardAddress;
      port = 5000;
      openFirewall = false;
      enableDelete = true;
      enableGarbageCollect = true;
      garbageCollectDates = "weekly";
      storagePath = "/var/lib/rezics-registry";
    };

    environment.systemPackages = [
      pkgs.acl
      pkgs.awscli2
      pkgs.devenv
      pkgs.docker
      pkgs.go-task
      pkgs.openssl
      pkgs.skopeo
      pkgs.socat
      releaseGateway
      reconcileRezicsDatabase
      rezicsNomad
      rezicsNomadInfrastructure
      rezicsNomadOperator
      runRezicsMaintenanceResponse
      runRezicsMaintenanceServer
      runRezicsRelease
      runRezicsReleaseBuild
      runRezicsReleaseMaintenance
      runRezicsServiceDeploy
      runDatabasusControlBackup
    ];

    environment.etc."rezics-release/api.nomad.hcl".source = ../jobs/edge/release/rezics-api.nomad.hcl;
    environment.etc."rezics-release/worker.nomad.hcl".source =
      ../jobs/edge/release/rezics-worker.nomad.hcl;
    environment.etc."rezics-platform/outline-app.nomad.hcl".source =
      ../jobs/edge/outline/outline-app.nomad.hcl;
    environment.etc."rezics-platform/outline-postgres.nomad.hcl".source =
      ../jobs/data/outline/outline-postgres.nomad.hcl;
    environment.etc."rezics-platform/signoz-store.nomad.hcl".source =
      ../jobs/data/observability/signoz-store.nomad.hcl;
    environment.etc."rezics-platform/signoz-core.nomad.hcl".source =
      ../jobs/edge/observability/signoz-core.nomad.hcl;
    environment.etc."rezics-platform/signoz-agent.nomad.hcl".source =
      ../jobs/edge/observability/signoz-agent.nomad.hcl;
    environment.etc."rezics-platform/databasus-control-backup.nomad.hcl".source =
      ../jobs/data/backup/databasus-control-backup.nomad.hcl;
    environment.etc."rezics-database/postgres.nomad.hcl".source =
      ../jobs/data/database/rezics-postgres.nomad.hcl;
    environment.etc."rezics-database/pgbouncer.nomad.hcl".source =
      ../jobs/data/database/rezics-pgbouncer.nomad.hcl;
    environment.etc."rezics-database/databasus.nomad.hcl".source =
      ../jobs/data/backup/databasus.nomad.hcl;
    environment.etc."rezics-database/databasus-verification-agent.nomad.hcl".source =
      ../jobs/data/backup/databasus-verification-agent.nomad.hcl;

    systemd.tmpfiles.rules = [
      "d /var/lib/rezics-ci 0700 rezics-ci rezics-ci - -"
      "d /var/lib/rezics-ci/docker 0700 rezics-ci rezics-ci - -"
      "d /var/lib/rezics-deploy 0750 rezics-deploy rezics-deploy - -"
      "d /var/lib/rezics-deploy/nomad-tls 0700 rezics-deploy rezics-deploy - -"
      "a+ /var/lib/rezics-deploy/nomad-tls - - - - m::r-x,u:root:r-x"
      "a+ /var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem - - - - u:root:r--"
      "a+ /var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem - - - - u:root:r--"
      "a+ /var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem - - - - u:root:r--"
      "d /var/lib/rezics-infrastructure-deploy 0750 rezics-infrastructure-deploy rezics-infrastructure-deploy - -"
      "d /var/lib/rezics-infrastructure-deploy/nomad-tls 0700 rezics-infrastructure-deploy rezics-infrastructure-deploy - -"
      "d /var/lib/rezics-release 0700 root root - -"
      "d /var/lib/rezics-release/workspaces 0711 root root - -"
      "d /var/lib/traefik/nomad-tls 0700 traefik traefik - -"
    ];

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
        providers = {
          providersThrottleDuration = "2s";
          nomad = {
            namespaces = [
              "default"
              "rezics"
              "rezics-infrastructure"
            ];
            exposedByDefault = false;
            watch = true;
            throttleDuration = "2s";
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
    };

    systemd.services.traefik = {
      after = [ "nomad.service" ];
      wants = [ "nomad.service" ];
      unitConfig.ConditionPathExists = [
        "/var/lib/traefik/nomad.env"
        "/var/lib/traefik/nomad-tls/nomad-agent-ca.pem"
        "/var/lib/traefik/nomad-tls/global-cli-nomad.pem"
        "/var/lib/traefik/nomad-tls/global-cli-nomad-key.pem"
      ];
    };

    systemd.services.rezics-release-gateway = {
      description = "GitHub OIDC to Nomad release gateway and protected admin proxy";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "nomad.service"
      ]
      ++ cfg.credentialProvisioningUnits;
      wants = [ "network-online.target" ];
      requires = [ "nomad.service" ];
      unitConfig.ConditionPathExists = [
        "/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
      ];
      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        ExecStart = gatewayStart;
        LoadCredential = [
          "admin-username:${cfg.credentialFiles.releaseGatewayAdminUsername}"
          "admin-password:${cfg.credentialFiles.releaseGatewayAdminPassword}"
          "admin-token:${cfg.credentialFiles.releaseGatewayNomadToken}"
          "nomad-ca:/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
          "nomad-client-cert:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
          "nomad-client-key:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
        ];
        Restart = "on-failure";
        RestartSec = "3s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };

    systemd.services.rezics-delivery-reconcile = {
      description = "Reconcile REZICS release OIDC, component jobs, and scoped variables";
      wantedBy = [ "multi-user.target" ];
      after = [ "nomad.service" ] ++ cfg.credentialProvisioningUnits;
      requires = [ "nomad.service" ];
      unitConfig.ConditionPathExists = [
        "/root/.config/nomad/management.token"
        "/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
      ];
      path = [ reconcileRezicsDelivery ];
      environment = {
        REZICS_API_MAINTENANCE_JOB_FILE = ../jobs/edge/rezics-api-maintenance.nomad.hcl;
        REZICS_RELEASE_API_DEPLOY_JOB_FILE = ../jobs/edge/release/rezics-release-api-deploy.nomad.hcl;
        REZICS_RELEASE_BUILD_JOB_FILE = ../jobs/edge/release/rezics-release-build.nomad.hcl;
        REZICS_RELEASE_DATABASE_JOB_FILE = ../jobs/edge/release/rezics-release-database.nomad.hcl;
        REZICS_RELEASE_JOB_FILE = ../jobs/edge/release/rezics-release.nomad.hcl;
        REZICS_RELEASE_MAINTENANCE_JOB_FILE = ../jobs/edge/release/rezics-release-maintenance.nomad.hcl;
        REZICS_RELEASE_PROJECTION_JOB_FILE = ../jobs/edge/release/rezics-release-projection.nomad.hcl;
        REZICS_RELEASE_WORKER_DEPLOY_JOB_FILE = ../jobs/edge/release/rezics-release-worker-deploy.nomad.hcl;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${reconcileRezicsDelivery}/bin/reconcile-rezics-delivery";
        LoadCredential = [
          "gateway-admin-token:${cfg.credentialFiles.releaseGatewayNomadToken}"
        ];
        Environment = [
          "REZICS_GATEWAY_ADMIN_TOKEN_FILE=%d/gateway-admin-token"
        ];
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "strict";
        ReadOnlyPaths = [
          "/root/.config/nomad/management.token"
          "/var/lib/rezics-deploy/nomad-tls"
        ];
      };
    };

    systemd.services.rezics-platform-reconcile = {
      description = "Reconcile split REZICS platform and observability jobs";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "nomad.service"
        "rezics-delivery-reconcile.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "nomad.service" ];
      unitConfig.ConditionPathExists = [
        "/root/.config/nomad/management.token"
        "/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
      ];
      environment = {
        REZICS_OUTLINE_APP_JOB_FILE = "/etc/rezics-platform/outline-app.nomad.hcl";
        REZICS_OUTLINE_DB_JOB_FILE = "/etc/rezics-platform/outline-postgres.nomad.hcl";
        REZICS_SIGNOZ_STORE_JOB_FILE = "/etc/rezics-platform/signoz-store.nomad.hcl";
        REZICS_SIGNOZ_CORE_JOB_FILE = "/etc/rezics-platform/signoz-core.nomad.hcl";
        REZICS_SIGNOZ_AGENT_JOB_FILE = "/etc/rezics-platform/signoz-agent.nomad.hcl";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${reconcileRezicsPlatform}/bin/reconcile-rezics-platform";
        LoadCredential = [
          "management-token:/root/.config/nomad/management.token"
          "nomad-ca:/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
          "nomad-client-cert:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
          "nomad-client-key:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
          "signoz-tokenizer-jwt-secret:${cfg.credentialFiles.signozTokenizerJwtSecret}"
          "signoz-root-email:${cfg.credentialFiles.signozRootEmail}"
          "signoz-root-password:${cfg.credentialFiles.signozRootPassword}"
          "signoz-root-org-name:${cfg.credentialFiles.signozRootOrgName}"
          "signoz-root-org-id:${cfg.credentialFiles.signozRootOrgId}"
        ];
        Environment = [
          "REZICS_NOMAD_MANAGEMENT_TOKEN_FILE=%d/management-token"
          "NOMAD_CACERT=%d/nomad-ca"
          "NOMAD_CLIENT_CERT=%d/nomad-client-cert"
          "NOMAD_CLIENT_KEY=%d/nomad-client-key"
          "REZICS_SIGNOZ_TOKENIZER_JWT_SECRET_FILE=%d/signoz-tokenizer-jwt-secret"
          "REZICS_SIGNOZ_ROOT_EMAIL_FILE=%d/signoz-root-email"
          "REZICS_SIGNOZ_ROOT_PASSWORD_FILE=%d/signoz-root-password"
          "REZICS_SIGNOZ_ROOT_ORG_NAME_FILE=%d/signoz-root-org-name"
          "REZICS_SIGNOZ_ROOT_ORG_ID_FILE=%d/signoz-root-org-id"
        ];
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "strict";
      };
    };

    systemd.services.rezics-signoz-provision = {
      description = "Reconcile SigNoz retention and REZICS dashboards";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "rezics-platform-reconcile.service"
      ]
      ++ cfg.credentialProvisioningUnits;
      wants = [ "network-online.target" ];
      requires = [ "rezics-platform-reconcile.service" ];
      path = [ provisionSignoz ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${provisionSignoz}/bin/provision-rezics-signoz";
        LoadCredential = [
          "signoz-root-email:${cfg.credentialFiles.signozRootEmail}"
          "signoz-root-password:${cfg.credentialFiles.signozRootPassword}"
          "signoz-root-org-id:${cfg.credentialFiles.signozRootOrgId}"
        ];
        Environment = [
          "REZICS_SIGNOZ_ROOT_EMAIL_FILE=%d/signoz-root-email"
          "REZICS_SIGNOZ_ROOT_PASSWORD_FILE=%d/signoz-root-password"
          "REZICS_SIGNOZ_ROOT_ORG_ID_FILE=%d/signoz-root-org-id"
          "REZICS_SIGNOZ_DASHBOARD_FILES=${builtins.concatStringsSep ":" (map toString signozDashboards)}"
        ];
        TimeoutStartSec = "30m";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };

    systemd.services.rezics-database-reconcile = {
      description = "Reconcile REZICS PostgreSQL, PgBouncer, and Databasus jobs";
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [
        ../jobs/data/database/rezics-postgres.nomad.hcl
        ../jobs/data/database/rezics-pgbouncer.nomad.hcl
        ../jobs/data/backup/databasus.nomad.hcl
        ../jobs/data/backup/databasus-verification-agent.nomad.hcl
      ];
      after = [
        "network-online.target"
        "nomad.service"
        "rezics-platform-reconcile.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "nomad.service" ];
      unitConfig.ConditionPathExists = [
        "/root/.config/nomad/management.token"
        "/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
        "/etc/rezics-database/postgres.nomad.hcl"
        "/etc/rezics-database/pgbouncer.nomad.hcl"
        "/etc/rezics-database/databasus.nomad.hcl"
        "/etc/rezics-database/databasus-verification-agent.nomad.hcl"
      ];
      path = [ reconcileRezicsDatabase ];
      environment = {
        REZICS_POSTGRES_JOB_FILE = "/etc/rezics-database/postgres.nomad.hcl";
        REZICS_PGBOUNCER_JOB_FILE = "/etc/rezics-database/pgbouncer.nomad.hcl";
        REZICS_DATABASUS_JOB_FILE = "/etc/rezics-database/databasus.nomad.hcl";
        REZICS_DATABASUS_VERIFICATION_AGENT_JOB_FILE = "/etc/rezics-database/databasus-verification-agent.nomad.hcl";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${reconcileRezicsDatabase}/bin/reconcile-rezics-database";
        LoadCredential = [
          "management-token:/root/.config/nomad/management.token"
          "nomad-ca:/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
          "nomad-client-cert:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
          "nomad-client-key:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
        ];
        Environment = [
          "REZICS_NOMAD_MANAGEMENT_TOKEN_FILE=%d/management-token"
          "NOMAD_CACERT=%d/nomad-ca"
          "NOMAD_CLIENT_CERT=%d/nomad-client-cert"
          "NOMAD_CLIENT_KEY=%d/nomad-client-key"
        ];
        TimeoutStartSec = "30m";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = "read-only";
        ProtectSystem = "strict";
        ReadOnlyPaths = [
          "/root/.config/nomad/management.token"
          "/var/lib/rezics-deploy/nomad-tls"
          "/etc/rezics-database"
        ];
      };
    };

    systemd.services.rezics-databasus-control-backup = {
      description = "Cold encrypted backup of the Databasus control database";
      after = [
        "network-online.target"
        "nomad.service"
        "rezics-delivery-reconcile.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "nomad.service" ];
      unitConfig.ConditionPathExists = [
        "/root/.config/nomad/management.token"
        "/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
        "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
        "/etc/rezics-platform/databasus-control-backup.nomad.hcl"
      ];
      environment.REZICS_DATABASUS_CONTROL_BACKUP_JOB_FILE = "/etc/rezics-platform/databasus-control-backup.nomad.hcl";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${runDatabasusControlBackup}/bin/run-databasus-control-backup";
        LoadCredential = [
          "management-token:/root/.config/nomad/management.token"
          "nomad-ca:/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
          "nomad-client-cert:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
          "nomad-client-key:/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
        ];
        Environment = [
          "REZICS_NOMAD_MANAGEMENT_TOKEN_FILE=%d/management-token"
          "NOMAD_CACERT=%d/nomad-ca"
          "NOMAD_CLIENT_CERT=%d/nomad-client-cert"
          "NOMAD_CLIENT_KEY=%d/nomad-client-key"
        ];
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
