variable "release" {
  type    = string
  default = "manual"
}

variable "worker_image" {
  type = string
}

job "rezics-worker" {
  namespace   = "rezics"
  datacenters = ["dc1"]
  type        = "service"

  meta {
    release = var.release
  }

  group "worker" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "edge"
    }

    update {
      canary            = 1
      max_parallel      = 1
      health_check      = "checks"
      min_healthy_time  = "15s"
      healthy_deadline  = "10m"
      progress_deadline = "12m"
      auto_promote      = true
      auto_revert       = true
    }

    restart {
      attempts = 3
      interval = "10m"
      delay    = "10s"
      mode     = "delay"
    }

    network {
      mode = "host"

      port "health" {
        host_network = "loopback"
      }
    }

    task "worker" {
      driver = "docker"

      config {
        image        = var.worker_image
        force_pull   = true
        network_mode = "host"
        ports        = ["health"]
      }

      env {
        DEPLOYMENT_ENVIRONMENT = "production"
        DATABASE_POOL_MAX      = "6"
        NODE_ENV               = "production"
        OTEL_BSP_MAX_EXPORT_BATCH_SIZE = "128"
        OTEL_BSP_MAX_QUEUE_SIZE        = "512"
        OTEL_BSP_SCHEDULE_DELAY        = "5000"
        OTEL_EXPORTER_OTLP_ENDPOINT    = "http://10.64.0.1:4318"
        OTEL_EXPORTER_OTLP_PROTOCOL    = "http/protobuf"
        OTEL_EXPORTER_OTLP_TIMEOUT     = "10000"
        OTEL_METRICS_EXPORTER          = "otlp"
        OTEL_METRIC_EXPORT_INTERVAL    = "60000"
        OTEL_METRIC_EXPORT_TIMEOUT     = "10000"
        OTEL_RESOURCE_ATTRIBUTES       = "service.namespace=rezics"
        OTEL_TRACES_EXPORTER           = "otlp"
        OTEL_TRACES_SAMPLER            = "parentbased_always_on"
        REZICS_RELEASE         = var.release
      }

      template {
        data = <<-EOH
        WORKER_HEALTH_HOST=127.0.0.1
        WORKER_HEALTH_PORT={{ env "NOMAD_PORT_health" }}
        {{- with nomadVar "application/runtime" }}
        {{- range .Tuples }}
        {{ .K }}={{ .V | toJSON }}
        {{- end }}
        {{- end }}
        EOH

        destination = "secrets/runtime.env"
        env         = true
        change_mode = "restart"
      }

      service {
        provider     = "nomad"
        name         = "rezics-worker"
        port         = "health"
        address_mode = "host"

        check {
          name      = "worker-readiness"
          type      = "http"
          path      = "/ready"
          interval  = "5s"
          timeout   = "3s"
          on_update = "require_healthy"
        }

        check {
          name      = "worker-liveness"
          type      = "http"
          path      = "/health"
          interval  = "10s"
          timeout   = "1s"
          on_update = "require_healthy"

          check_restart {
            limit = 3
            grace = "10s"
          }
        }
      }

      kill_signal    = "SIGTERM"
      kill_timeout   = "30s"
      shutdown_delay = "5s"

      resources {
        cpu        = 2300
        memory     = 512
        memory_max = 2048
      }
    }
  }
}
