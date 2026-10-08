{ config, lib, ... }:
let
  cfg = config.services.rezicsMail;
in
{
  options.services.rezicsMail = {
    enable = lib.mkEnableOption "the single-node Stalwart mail service";
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
    publicInterface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
    };
  };
  config = lib.mkIf cfg.enable {
    services.stalwart = {
      enable = true;
      stateVersion = "26.05";
      openFirewall = false;
      credentials.admin = cfg.adminPasswordHashFile;
      settings = {
        server.hostname = cfg.hostname;
        server.listener = {
          smtp = {
            bind = [ "0.0.0.0:25" ];
            protocol = "smtp";
          };
          submission = {
            bind = [ "0.0.0.0:587" ];
            protocol = "smtp";
          };
          submissions = {
            bind = [ "0.0.0.0:465" ];
            protocol = "smtp";
            tls.implicit = true;
          };
          imaps = {
            bind = [ "0.0.0.0:993" ];
            protocol = "imap";
            tls.implicit = true;
          };
          https = {
            bind = [ "0.0.0.0:443" ];
            protocol = "http";
            tls.implicit = true;
          };
          management = {
            bind = [ "127.0.0.1:8085" ];
            protocol = "http";
          };
        };
        authentication.fallback-admin = {
          user = "admin";
          secret = "%{file:/run/credentials/stalwart.service/admin}%";
        };
        certificate.default = {
          cert = "%{file:/var/lib/acme/${cfg.hostname}/fullchain.pem}%";
          private-key = "%{file:/var/lib/acme/${cfg.hostname}/key.pem}%";
          default = true;
        };
        session.auth.require = [
          {
            "if" = "local_port != 25";
            "then" = true;
          }
          { "else" = false; }
        ];
        session.auth.mechanisms = [
          {
            "if" = "local_port != 25 && is_tls";
            "then" = "[plain, login]";
          }
          { "else" = "[]"; }
        ];
      };
    };
    security.acme = {
      acceptTerms = true;
      defaults.email = cfg.contactEmail;
      certs."${cfg.hostname}" = {
        listenHTTP = ":80";
        group = config.services.stalwart.group;
        reloadServices = [ "stalwart" ];
      };
    };
    systemd.services.stalwart = {
      wants = [ "acme-${cfg.hostname}.service" ];
      after = [ "acme-${cfg.hostname}.service" ];
      serviceConfig.MemoryMax = "2G";
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
