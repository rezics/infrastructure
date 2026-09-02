job "rezics-release-maintenance" {
  namespace = "rezics-release"
  type      = "batch"
  priority  = 90

  parameterized {
    payload       = "forbidden"
    meta_required = ["release", "commit"]
  }

  group "maintenance" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "edge"
    }

    restart {
      attempts = 0
      mode     = "fail"
    }

    reschedule {
      attempts  = 0
      unlimited = false
    }

    task "maintenance" {
      driver = "docker"
      user   = "992"

      config {
        image           = "debian@sha256:a347fd7510ee31a84387619a492ad6c8eb0af2f2682b916ff3e643eb076f925a"
        force_pull      = true
        readonly_rootfs = true
        init            = true
        pids_limit      = 128
        cap_drop        = ["all"]
        security_opt    = ["no-new-privileges"]
        network_mode    = "host"
        command         = "/run/current-system/sw/bin/run-rezics-release-maintenance"

        mount {
          type     = "bind"
          source   = "/nix/store"
          target   = "/nix/store"
          readonly = true
        }
        mount {
          type     = "bind"
          source   = "/etc/ssl/certs/ca-bundle.crt"
          target   = "/etc/ssl/certs/ca-bundle.crt"
          readonly = true
        }
        mount {
          type     = "bind"
          source   = "/run/current-system/sw"
          target   = "/run/current-system/sw"
          readonly = true
        }
        mount {
          type     = "bind"
          source   = "/var/lib/rezics-deploy"
          target   = "/var/lib/rezics-deploy"
          readonly = true
        }
        mount {
          type   = "tmpfs"
          target = "/tmp"
          tmpfs_options {
            size = 67108864
          }
        }
      }

      env {
        HOME          = "/alloc/data/home"
        PATH          = "/run/current-system/sw/bin:/bin"
        SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt"
        TMPDIR        = "/tmp"
      }

      resources {
        cpu        = 200
        memory     = 128
        memory_max = 256
      }

      kill_timeout = "10m"
    }
  }
}
