{
  config,
  lib,
  ...
}:
let
  cfg = config.services.rezicsFleet;
in
{
  options.services.rezicsFleet = {
    role = lib.mkOption {
      type = lib.types.enum [
        "edge"
        "data"
      ];
      default = "edge";
      description = "Nomad placement role for this host.";
    };

    nomadServer = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this host is the single Nomad server.";
    };

    wireguardInterface = lib.mkOption {
      type = lib.types.str;
      default = "wg-rezics";
    };

    wireguardAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.64.0.1";
    };

    wireguardPeerPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "The peer's WireGuard public key; private keys never belong in Nix.";
    };

    wireguardPeerEndpoint = lib.mkOption {
      type = lib.types.str;
      description = "The peer's public WireGuard endpoint.";
    };

    nomadServerAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.64.0.1:4647";
    };

    registryAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.64.0.1:5000";
    };

    operatorAuthorizedKey = lib.mkOption {
      type = lib.types.str;
      description = "The maintainer/operator SSH public key.";
    };

    rootPasswordHashFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/rezics/root-password-hash";
      description = "A runtime-only root password hash file.";
    };

    nomadReservedCpu = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2500;
    };

    nomadReservedMemory = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3072;
    };

    hostVolumes = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption { type = lib.types.str; };
            readOnly = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        }
      );
      default = { };
    };
  };

  config = {
    environment.etc."rezics/fleet-role".text = "${cfg.role}\n";

    networking.wireguard.interfaces."${cfg.wireguardInterface}" = {
      ips = [ "${cfg.wireguardAddress}/30" ];
      listenPort = 51820;
      privateKeyFile = "/var/lib/wireguard/${cfg.wireguardInterface}.key";
      peers = [
        {
          publicKey = cfg.wireguardPeerPublicKey;
          endpoint = cfg.wireguardPeerEndpoint;
          allowedIPs = [
            "${if cfg.role == "edge" then "10.64.0.2" else "10.64.0.1"}/32"
          ];
          persistentKeepalive = 25;
        }
      ];
    };

    networking.firewall.interfaces."${cfg.wireguardInterface}" = {
      allowedTCPPorts = [
        4317
        4318
        4646
        4647
        4648
        5000
        5432
        55432
        15001
        20242
        20243
      ];
      allowedUDPPorts = [ 51820 ];
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/wireguard 0700 root root - -"
      "d /var/lib/rezics 0710 root root - -"
    ];

    systemd.services."wireguard-${cfg.wireguardInterface}".unitConfig.ConditionPathExists =
      "/var/lib/wireguard/${cfg.wireguardInterface}.key";
  };
}
