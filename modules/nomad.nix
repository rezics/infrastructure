{
  config,
  lib,
  pkgs,
  ...
}:
let
  fleet = config.services.rezicsFleet;
  nomad = pkgs.stdenvNoCC.mkDerivation {
    pname = "nomad";
    version = "2.0.4";

    src = pkgs.fetchurl {
      url = "https://releases.hashicorp.com/nomad/2.0.4/nomad_2.0.4_linux_amd64.zip";
      hash = "sha256-9rDVVfZd59ge8ydNfX38rW/yTW5iFKgG3rXFC5CeR7c=";
    };

    dontUnpack = true;
    nativeBuildInputs = [ pkgs.unzip ];
    installPhase = ''
      runHook preInstall
      install -d "$out/bin"
      unzip "$src" -d "$out/bin"
      chmod 0755 "$out/bin/nomad"
      runHook postInstall
    '';

    meta = {
      description = "Nomad workload orchestrator";
      homepage = "https://www.nomadproject.io/";
      license = pkgs.lib.licenses.bsl11;
      mainProgram = "nomad";
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      "live-restore" = true;
      "log-driver" = "local";
      "log-opts" = {
        compress = "true";
        "max-file" = "5";
        "max-size" = "20m";
      };
      "no-new-privileges" = true;
      "userland-proxy" = false;
      "insecure-registries" = [ fleet.registryAddress ];
    };
    autoPrune = {
      enable = true;
      dates = "weekly";
      flags = [ "--filter=until=720h" ];
      randomizedDelaySec = "45min";
    };
  };

  services.nomad = {
    enable = true;
    package = nomad;
    enableDocker = true;
    dropPrivileges = false;
    extraSettingsPaths = [ "/etc/nomad.d" ];
    credentials.cluster-secrets = "/var/lib/nomad/secrets/cluster.json";

    settings = {
      bind_addr = fleet.wireguardAddress;
      datacenter = "dc1";
      disable_anonymous_signature = true;
      disable_update_check = true;
      leave_on_interrupt = true;
      leave_on_terminate = true;
      log_json = true;
      region = "global";

      addresses = {
        http = "127.0.0.1";
        rpc = fleet.wireguardAddress;
        serf = fleet.wireguardAddress;
      };
      advertise = {
        http = "127.0.0.1:4646";
        rpc = "${fleet.wireguardAddress}:4647";
        serf = "${fleet.wireguardAddress}:4648";
      };

      acl = {
        enabled = true;
        policy_ttl = "30s";
        role_ttl = "30s";
        token_ttl = "30s";
      };

      consul = {
        auto_advertise = false;
        client_auto_join = false;
        server_auto_join = false;
      };

      tls = {
        http = true;
        rpc = true;
        tls_min_version = "tls13";
        ca_file = "/var/lib/nomad/tls/nomad-agent-ca.pem";
        cert_file = "/var/lib/nomad/tls/global-server-nomad.pem";
        key_file = "/var/lib/nomad/tls/global-server-nomad-key.pem";
        verify_https_client = true;
        verify_server_hostname = true;
      };

      server = {
        enabled = fleet.nomadServer;
        bootstrap_expect = lib.mkIf fleet.nomadServer 1;
      };

      client = {
        enabled = true;
        node_class = fleet.role;
        meta = {
          role = fleet.role;
        };
        servers = [ fleet.nomadServerAddress ];
        cni_path = "${pkgs.cni-plugins}/bin";
        max_kill_timeout = "2m";
        reserved = {
          cpu = fleet.nomadReservedCpu;
          memory = fleet.nomadReservedMemory;
        };
        bridge_network_subnet = "172.26.64.0/20";
        host_network.loopback = {
          cidr = "127.0.0.1/8";
          reserved_ports = "4646-4648,5000,8080,15000-15399,20242-20243";
        };
        host_network.wireguard = {
          interface = fleet.wireguardInterface;
          cidr = "${fleet.wireguardAddress}/32";
          # Reserve only host-owned control-plane ports. PostgreSQL, Outline,
          # and OTLP are Nomad workloads and must remain allocatable here.
          reserved_ports = "4646-4648,5000,15000-15399,20242-20243";
        };
        host_volume = lib.mapAttrs (_name: volume: {
          path = volume.path;
          read_only = volume.readOnly;
        }) fleet.hostVolumes;
      };

      telemetry = {
        collection_interval = "10s";
        disable_hostname = true;
        prometheus_metrics = true;
        publish_allocation_metrics = true;
        publish_node_metrics = true;
      };

      ui.enabled = true;
    };
  };

  environment.etc."nomad.d/docker.hcl".text = ''
    plugin "docker" {
      config {
        allow_privileged = false
        auth {
          config = "/var/lib/nomad/secrets/docker-config.json"
        }
        gc {
          image = true
        }
        volumes {
          enabled = true
        }
      }
    }
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/nomad/secrets 0700 root root - -"
    "d /var/lib/nomad/tls 0700 root root - -"
    "d /var/lib/rezics 0710 root root - -"
    # PostgreSQL 18 switches to its unprivileged UID after creating PGDATA;
    # keep only traversal on the bind-mounted parent while PGDATA remains 0700.
    "d /var/lib/rezics/postgres 0711 root root - -"
    # Databasus stores its control database as UID 65532 inside the container.
    "d /var/lib/rezics/databasus 0711 65532 65532 - -"
    "d /var/lib/rezics/signoz 0711 root root - -"
    "d /var/lib/rezics/signoz/clickhouse 0711 root root - -"
    "d /var/lib/rezics/signoz/clickhouse-user-scripts 0755 root root - -"
    "d /var/lib/rezics/signoz/keeper 0711 root root - -"
    "d /var/lib/rezics/signoz/sqlite 0711 root root - -"
    "d /var/lib/outline 0711 root root - -"
    "d /var/lib/outline/data 0711 root root - -"
    "d /var/lib/outline/postgres 0711 root root - -"
  ];

  systemd.services.nomad = {
    after = [
      "docker.service"
      "wireguard-${fleet.wireguardInterface}.service"
    ];
    requires = [
      "docker.service"
      "wireguard-${fleet.wireguardInterface}.service"
    ];
    unitConfig.ConditionPathExists = [
      "/var/lib/nomad/secrets/cluster.json"
      "/var/lib/nomad/tls/nomad-agent-ca.pem"
      "/var/lib/nomad/tls/global-server-nomad.pem"
      "/var/lib/nomad/tls/global-server-nomad-key.pem"
    ];
    serviceConfig.UMask = "0077";
  };
}
