job "rezics-api-maintenance" {
  namespace   = "rezics"
  datacenters = ["dc1"]
  type        = "service"
  priority    = 20

  group "maintenance" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "edge"
    }

    restart {
      attempts = 5
      interval = "10m"
      delay    = "5s"
      mode     = "delay"
    }

    network {
      mode = "host"

      port "http" {
        host_network = "loopback"
      }
    }

    task "maintenance" {
      driver = "docker"
      user   = "65534"

      config {
        image           = "debian@sha256:a347fd7510ee31a84387619a492ad6c8eb0af2f2682b916ff3e643eb076f925a"
        force_pull      = true
        readonly_rootfs = true
        init            = true
        pids_limit      = 64
        cap_drop        = ["all"]
        security_opt    = ["no-new-privileges"]
        network_mode    = "host"
        ports           = ["http"]
        command         = "/run/current-system/sw/bin/run-rezics-maintenance-server"

        mount {
          type     = "bind"
          source   = "/nix/store"
          target   = "/nix/store"
          readonly = true
        }
        mount {
          type     = "bind"
          source   = "/run/current-system/sw"
          target   = "/run/current-system/sw"
          readonly = true
        }
      }

      env {
        REZICS_MAINTENANCE_HOST = "${NOMAD_IP_http}"
        REZICS_MAINTENANCE_PORT = "${NOMAD_PORT_http}"
      }

      service {
        provider     = "nomad"
        name         = "rezics-api-maintenance"
        port         = "http"
        address_mode = "host"
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.rezics-api-maintenance.entrypoints=web",
          "traefik.http.routers.rezics-api-maintenance.priority=1",
          "traefik.http.routers.rezics-api-maintenance.rule=Host(`api.rezics.com`) || Host(`rezics-maintenance.internal`)",
        ]

        check {
          name     = "maintenance-readiness"
          type     = "http"
          path     = "/_health"
          interval = "10s"
          timeout  = "2s"
        }
      }

      kill_signal    = "SIGTERM"
      kill_timeout   = "10s"
      shutdown_delay = "5s"

      resources {
        cpu        = 100
        memory     = 32
        memory_max = 64
      }
    }
  }
}
