job "rezics-release-build" {
  namespace = "rezics-release"
  type      = "batch"
  priority  = 85

  parameterized {
    payload       = "forbidden"
    meta_required = ["workspace_id", "release", "commit", "components"]
  }

  group "build" {
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

    ephemeral_disk {
      size    = 4096
      sticky  = false
      migrate = false
    }

    task "build" {
      driver = "docker"
      user   = "989"

      config {
        image           = "debian@sha256:a347fd7510ee31a84387619a492ad6c8eb0af2f2682b916ff3e643eb076f925a"
        force_pull      = true
        readonly_rootfs = true
        init            = true
        pids_limit      = 1024
        cap_drop        = ["all"]
        security_opt    = ["no-new-privileges"]
        network_mode    = "host"
        command         = "/run/current-system/sw/bin/run-rezics-release-build"

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
          source   = "/run/user/989/docker.sock"
          target   = "/run/user/989/docker.sock"
          readonly = false
        }
        mount {
          type     = "bind"
          source   = "/var/lib/rezics-release/workspaces"
          target   = "/var/lib/rezics-release/workspaces"
          readonly = false
        }
        mount {
          type   = "tmpfs"
          target = "/tmp"
          tmpfs_options {
            size = 1073741824
          }
        }
      }

      env {
        DOCKER_HOST                    = "unix:///run/user/989/docker.sock"
        HOME                           = "/alloc/data/home"
        PATH                           = "/run/current-system/sw/bin:/bin"
        REZICS_RELEASE_STATE_DIRECTORY = "/var/lib/rezics-release"
        SSL_CERT_FILE                  = "/etc/ssl/certs/ca-bundle.crt"
        TMPDIR                         = "/alloc/tmp/rezics"
      }

      resources {
        cpu        = 4000
        memory     = 2048
        memory_max = 4096
      }

      kill_timeout = "3h"
    }
  }
}
