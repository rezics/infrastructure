job "rezics-release-database" {
  namespace = "rezics-release"
  type      = "batch"
  priority  = 85

  parameterized {
    payload       = "forbidden"
    meta_required = ["release", "commit", "database_image"]
  }

  group "database" {
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

    network {
      mode = "host"
    }

    task "database" {
      driver = "docker"

      identity {
        env = true
      }

      config {
        image        = "${NOMAD_META_database_image}"
        force_pull   = true
        network_mode = "host"
        args         = ["release"]
      }

      env {
        DEPLOYMENT_ENVIRONMENT   = "production"
        NODE_ENV                 = "production"
        REZICS_EXPECTED_DATABASE = "rezics"
        REZICS_RELEASE           = "${NOMAD_META_release}"
      }

      template {
        data = <<-EOH
        {{- with nomadVar "release/database" -}}
        {{- range .Tuples }}
        {{ .K }}={{ .V | toJSON }}
        {{- end }}
        {{- end }}
        EOH

        destination = "secrets/database.env"
        env         = true
        perms       = "0600"
      }

      resources {
        cpu        = 1500
        memory     = 1024
        memory_max = 2048
      }

      kill_timeout = "30m"
    }
  }
}
