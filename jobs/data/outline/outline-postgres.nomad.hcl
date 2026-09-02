job "outline-postgres" {
  namespace   = "default"
  datacenters = ["dc1"]
  type        = "service"

  group "postgres" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "data"
    }

    network {
      mode = "host"

      port "postgres" {
        static       = 55432
        host_network = "wireguard"
      }
    }

    volume "postgres" {
      type      = "host"
      source    = "outline-postgres"
      read_only = false
    }

    task "postgres" {
      driver = "docker"

      config {
        image        = "postgres@sha256:081f1bc7bd5e143dbb6e487b710bbc27712cdcfaced4c071b8e47349aa1b4171"
        force_pull   = true
        network_mode = "host"
        ports        = ["postgres"]
        args = [
          "-c", "listen_addresses=10.64.0.2",
          "-c", "port=55432",
          "-c", "password_encryption=scram-sha-256",
          "-c", "max_connections=40",
          "-c", "shared_buffers=256MB",
        ]
      }

      env {
        PGDATA      = "/var/lib/postgresql/16/docker"
        POSTGRES_DB = "outline"
      }

      template {
        data = <<-EOH
        {{- with nomadVar "nomad/jobs/outline" }}
        POSTGRES_USER={{ .postgres_username | toJSON }}
        POSTGRES_PASSWORD={{ .postgres_password | toJSON }}
        {{- end }}
        EOH
        destination = "secrets/runtime.env"
        env         = true
        change_mode = "restart"
        perms       = "0400"
      }

      volume_mount {
        volume      = "postgres"
        destination = "/var/lib/postgresql"
        read_only   = false
      }

      service {
        name         = "outline-postgres"
        port         = "postgres"
        provider     = "nomad"
        address_mode = "host"

        check {
          name     = "postgres-tcp"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }

      kill_signal  = "SIGINT"
      kill_timeout = "2m"

      resources {
        cpu        = 1000
        memory     = 256
        memory_max = 1024
      }
    }
  }
}
