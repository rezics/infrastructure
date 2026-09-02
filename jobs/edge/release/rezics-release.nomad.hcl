job "rezics-release" {
  namespace = "rezics-release"
  type      = "batch"
  priority  = 90

  parameterized {
    payload       = "forbidden"
    meta_required = ["repository", "sha", "ref", "run_id", "run_attempt", "event_name"]
    meta_optional = ["actor"]
  }

  group "controller" {
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
      size    = 2048
      sticky  = false
      migrate = false
    }

    task "controller" {
      driver = "docker"
      user   = "0"

      identity {
        env = true
      }

      config {
        image           = "debian@sha256:a347fd7510ee31a84387619a492ad6c8eb0af2f2682b916ff3e643eb076f925a"
        force_pull      = true
        readonly_rootfs = true
        init            = true
        pids_limit      = 512
        cap_drop        = ["all"]
        security_opt    = ["no-new-privileges"]
        network_mode    = "host"
        command         = "/run/current-system/sw/bin/bash"
        args = [
          "-c",
          <<-EOC
          set -euo pipefail
          exec 2>&1
          workspace="/var/lib/rezics-release/workspaces/$NOMAD_ALLOC_ID"
          repository="$workspace/source"
          workload_repository="$workspace/workload"
          cleanup() {
            find "$workspace" -depth -delete
          }
          trap cleanup EXIT
          install -d -m 0711 "$workspace"
          install -d -m 0700 "$repository" "$HOME" "$TMPDIR"
          git init "$repository"
          cd "$repository"
          git remote add origin "https://github.com/$NOMAD_META_repository.git"
          git -c protocol.version=2 fetch --filter=blob:none --no-tags origin \
            "refs/heads/main:refs/remotes/origin/main" \
            "$NOMAD_META_ref:$NOMAD_META_ref"
          observed_sha="$(git rev-parse "$NOMAD_META_ref^{commit}")"
          test "$observed_sha" = "$NOMAD_META_sha"
          git checkout --detach "$observed_sha"
          install -d -m 0700 "$workload_repository"
          cp -a "$repository/." "$workload_repository/"
          setfacl --recursive --modify user:989:rwX "$workload_repository"
          setfacl --modify default:user:989:rwX "$workload_repository"
          release="$(printf '%s' "$NOMAD_META_ref" | sed 's#^refs/tags/##')"
          run-rezics-release \
            "$repository" "$workload_repository" "$release" "$observed_sha"
          EOC
        ]

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
          source   = "/var/lib/rezics-deploy/nomad-tls"
          target   = "/var/lib/rezics-deploy/nomad-tls"
          readonly = true
        }
        mount {
          type     = "bind"
          source   = "/var/lib/rezics-release"
          target   = "/var/lib/rezics-release"
          readonly = false
        }
        mount {
          type   = "tmpfs"
          target = "/tmp"
          tmpfs_options {
            size = 536870912
          }
        }
      }

      env {
        HOME                           = "/alloc/data/home"
        NOMAD_ADDR                     = "https://127.0.0.1:4646"
        NOMAD_CACERT                   = "/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem"
        NOMAD_CLIENT_CERT              = "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem"
        NOMAD_CLIENT_KEY               = "/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem"
        NOMAD_NAMESPACE                = "rezics-release"
        NOMAD_TLS_SERVER_NAME          = "server.global.nomad"
        PATH                           = "/run/current-system/sw/bin:/bin"
        REZICS_RELEASE_STATE_DIRECTORY = "/var/lib/rezics-release"
        REZICS_REGISTRY_ADDRESS        = "10.64.0.1:5000"
        SSL_CERT_FILE                  = "/etc/ssl/certs/ca-bundle.crt"
        TMPDIR                         = "/alloc/tmp/rezics"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }

      kill_timeout = "6h"
    }
  }
}
