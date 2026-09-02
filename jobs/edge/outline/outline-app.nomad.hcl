job "outline-app" {
  namespace   = "default"
  datacenters = ["dc1"]
  type        = "service"

  group "redis" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "edge"
    }

    network {
      mode = "host"

      port "redis" {
        static       = 6379
        host_network = "loopback"
      }
    }

    service {
      name         = "outline-redis"
      port         = "redis"
      provider     = "nomad"
      address_mode = "host"
    }

    task "redis" {
      driver = "docker"

      config {
        image        = "redis@sha256:33d7c9a245edd95e6703a0addbeaa48fe40c3b3b4783627a72085155462ebfdb"
        force_pull   = true
        network_mode = "host"
        ports        = ["redis"]
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 256
      }
    }
  }

  group "outline" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "edge"
    }

    network {
      mode = "host"

      port "http" {
        static       = 3100
        host_network = "loopback"
      }
    }

    volume "outline-data" {
      type      = "host"
      source    = "outline-data"
      read_only = false
    }

    service {
      name         = "outline"
      port         = "http"
      provider     = "nomad"
      address_mode = "host"
      tags = [
        "traefik.enable=true",
        "traefik.http.routers.outline.entrypoints=web",
        "traefik.http.routers.outline.rule=Host(`outline.rezics.com`)",
      ]

      check {
        name     = "outline-health"
        type     = "http"
        path     = "/_health"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "outline" {
      driver = "docker"

      config {
        image        = "docker.getoutline.com/outlinewiki/outline@sha256:32d76719c378931dd65d93945930ca380d8376a0337d98a991fcc12b266f33cf"
        force_pull   = true
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "outline-data"
        destination = "/var/lib/outline/data"
        read_only   = false
      }

      env {
        NODE_ENV                       = "production"
        DATABASE_CONNECTION_POOL_MIN   = "0"
        DATABASE_CONNECTION_POOL_MAX   = "10"
        PGSSLMODE                      = "disable"
        URL                            = "https://outline.rezics.com"
        PORT                           = "3100"
        REDIS_URL                      = "redis://127.0.0.1:6379"
        FILE_STORAGE                   = "s3"
        FILE_STORAGE_LOCAL_ROOT_DIR    = "/var/lib/outline/data"
        FILE_STORAGE_UPLOAD_MAX_SIZE   = "262144000"
        AWS_ACCESS_KEY_ID_FILE         = "/secrets/r2_access_key_id"
        AWS_SECRET_ACCESS_KEY_FILE     = "/secrets/r2_secret_access_key"
        AWS_REGION                     = "auto"
        AWS_S3_UPLOAD_BUCKET_URL       = "https://dcc939f004008f8e36e11456df3f0fe2.eu.r2.cloudflarestorage.com"
        AWS_S3_UPLOAD_BUCKET_NAME      = "outline"
        AWS_S3_FORCE_PATH_STYLE        = "true"
        AWS_S3_ACL                     = "private"
        AWS_S3_UPLOAD_METHOD           = "put"
        FORCE_HTTPS                    = "false"
      }

      template {
        data = <<-EOH
        {{- with nomadVar "nomad/jobs/outline" }}
        DATABASE_URL={{ .database_url | toJSON }}
        SECRET_KEY={{ .secret_key | toJSON }}
        UTILS_SECRET={{ .utils_secret | toJSON }}
        SMTP_HOST={{ .smtp_host | toJSON }}
        SMTP_PORT={{ .smtp_port | toJSON }}
        SMTP_USERNAME={{ .smtp_username | toJSON }}
        SMTP_PASSWORD={{ .smtp_password | toJSON }}
        SMTP_FROM_EMAIL={{ .smtp_from_email | toJSON }}
        SMTP_SECURE={{ .smtp_secure | toJSON }}
        GITHUB_CLIENT_ID={{ .github_client_id | toJSON }}
        GITHUB_CLIENT_SECRET={{ .github_client_secret | toJSON }}
        GITHUB_APP_NAME={{ .github_app_name | toJSON }}
        GITHUB_APP_ID={{ .github_app_id | toJSON }}
        GITHUB_APP_PRIVATE_KEY={{ .github_app_private_key | toJSON }}
        AWS_S3_UPLOAD_BUCKET_URL={{ .r2_endpoint | toJSON }}
        AWS_S3_UPLOAD_BUCKET_NAME={{ .r2_bucket | toJSON }}
        {{- end }}
        EOH

        destination = "secrets/runtime.env"
        env         = true
        change_mode = "restart"
        perms       = "0400"
      }

      template {
        data = <<-EOH
        {{- with nomadVar "nomad/jobs/outline" }}{{ .r2_access_key_id }}{{ end }}
        EOH
        destination = "secrets/r2_access_key_id"
        change_mode = "restart"
        perms       = "0400"
        uid         = 1001
        gid         = 1001
      }

      template {
        data = <<-EOH
        {{- with nomadVar "nomad/jobs/outline" }}{{ .r2_secret_access_key }}{{ end }}
        EOH
        destination = "secrets/r2_secret_access_key"
        change_mode = "restart"
        perms       = "0400"
        uid         = 1001
        gid         = 1001
      }

      resources {
        cpu        = 2300
        memory     = 512
        memory_max = 1024
      }
    }
  }
}
