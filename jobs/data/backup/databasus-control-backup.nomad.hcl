job "rezics-databasus-control-backup" {
  namespace   = "rezics-infrastructure"
  datacenters = ["dc1"]
  type        = "batch"

  group "backup" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "data"
    }

    restart {
      attempts = 0
      mode     = "fail"
    }

    reschedule {
      attempts  = 0
      unlimited = false
    }

    volume "databasus" {
      type      = "host"
      source    = "rezics-databasus"
      read_only = true
    }

    task "backup" {
      driver = "docker"

      config {
        image      = "restic/restic@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76"
        force_pull = true
        entrypoint = ["/bin/sh"]
        args       = ["/local/run-backup.sh"]
      }

      volume_mount {
        volume      = "databasus"
        destination = "/databasus-data"
        read_only   = true
      }

      env {
        AWS_DEFAULT_REGION = "auto"
        AWS_REGION         = "auto"
        RESTIC_REPOSITORY   = "s3:https://dcc939f004008f8e36e11456df3f0fe2.r2.cloudflarestorage.com/rezics-production-postgres-backups/postgresql/databasus/control/restic"
      }

      template {
        destination = "secrets/restic.env"
        change_mode = "noop"
        env         = true
        perms       = "0400"
        data        = <<-EOH
        {{- with nomadVar "database/databasus-control-backup" }}
        AWS_ACCESS_KEY_ID={{ .AWS_ACCESS_KEY_ID | toJSON }}
        AWS_SECRET_ACCESS_KEY={{ .AWS_SECRET_ACCESS_KEY | toJSON }}
        RESTIC_PASSWORD={{ .RESTIC_PASSWORD | toJSON }}
        {{- end }}
        EOH
      }

      template {
        destination = "secrets/secret.key"
        change_mode = "noop"
        perms       = "0400"
        data        = <<-EOH
        {{- with nomadVar "database/databasus-control" }}{{ .DATABASUS_SECRET_KEY }}{{ end }}
        EOH
      }

      template {
        destination = "local/run-backup.sh"
        change_mode = "noop"
        perms       = "0500"
        data        = <<-EOH
        #!/bin/sh
        set -eu

        pgdata=/databasus-data/pgdata
        secret_key=/secrets/secret.key
        restore_root=/local/restore-check

        test -s "$${pgdata}/PG_VERSION"
        test -s "$${secret_key}"
        if ! restic --no-lock snapshots --tag databasus-control >/dev/null 2>&1; then
          restic init
        fi

        restic --no-lock backup --no-cache \
          --host B \
          --tag databasus-control \
          "$${pgdata}" "$${secret_key}"
        restic --no-lock check --no-cache --read-data

        rm -rf "$${restore_root}"
        restic --no-lock restore --no-cache \
          --host B \
          --tag databasus-control \
          --target "$${restore_root}" \
          latest
        test -s "$${restore_root}/databasus-data/pgdata/PG_VERSION"
        test -s "$${restore_root}/secrets/secret.key"

        # R2 Object Lock intentionally prevents deletion of Restic's short-lived
        # lock objects. Audit the GFS selection without weakening immutability;
        # snapshots remain append-only and are reviewed before later pruning.
        restic --no-lock forget --no-cache --dry-run \
          --host B \
          --tag databasus-control \
          --keep-daily 7 \
          --keep-weekly 4
        EOH
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
