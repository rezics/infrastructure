job "signoz-core" {
  namespace   = "rezics-infrastructure"
  datacenters = ["dc1"]
  type        = "service"

  group "core" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "edge"
    }

    network {
      mode = "bridge"

      port "http" {
        static       = 3080
        to           = 8080
        host_network = "loopback"
      }

      port "otlp-grpc" {
        static       = 4317
        to           = 4317
        host_network = "wireguard"
      }

      port "otlp-http" {
        static       = 4318
        to           = 4318
        host_network = "wireguard"
      }
    }

    volume "sqlite" {
      type      = "host"
      source    = "signoz-sqlite"
      read_only = false
    }

    task "signoz" {
      driver = "docker"

      config {
        image      = "signoz/signoz@sha256:f23caccc88dad6f7e31f429681b5cc2f5fcdef5f6dd200924f705063b288bada"
        force_pull = true
        ports      = ["http"]
      }

      env {
        SIGNOZ_SQLSTORE_PROVIDER             = "sqlite"
        SIGNOZ_SQLSTORE_SQLITE_PATH          = "/var/lib/signoz/signoz.db"
        SIGNOZ_SQLSTORE_SQLITE_MODE          = "wal"
        SIGNOZ_TELEMETRYSTORE_PROVIDER       = "clickhouse"
        SIGNOZ_TELEMETRYSTORE_CLICKHOUSE_DSN = "tcp://10.64.0.2:9000"
      }

      template {
        destination = "secrets/runtime.env"
        env         = true
        change_mode = "restart"
        perms       = "0400"
        data        = <<-EOH
        {{- with nomadVar "nomad/jobs/signoz-core" -}}
        SIGNOZ_TOKENIZER_JWT_SECRET={{ .SIGNOZ_TOKENIZER_JWT_SECRET | toJSON }}
        SIGNOZ_USER_ROOT_ENABLED=true
        SIGNOZ_USER_ROOT_EMAIL={{ .SIGNOZ_USER_ROOT_EMAIL | toJSON }}
        SIGNOZ_USER_ROOT_PASSWORD={{ .SIGNOZ_USER_ROOT_PASSWORD | toJSON }}
        SIGNOZ_USER_ROOT_ORG_NAME={{ .SIGNOZ_USER_ROOT_ORG_NAME | toJSON }}
        SIGNOZ_USER_ROOT_ORG_ID={{ .SIGNOZ_USER_ROOT_ORG_ID | toJSON }}
        {{- end }}
        EOH
      }

      volume_mount {
        volume      = "sqlite"
        destination = "/var/lib/signoz"
        read_only   = false
      }

      service {
        name         = "signoz"
        port         = "http"
        provider     = "nomad"
        address_mode = "host"
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.signoz.entrypoints=web",
          "traefik.http.routers.signoz.rule=Host(`signoz.rezics.com`)",
        ]

        check {
          name     = "signoz-health"
          type     = "http"
          path     = "/api/v1/health"
          interval = "15s"
          timeout  = "5s"
        }
      }

      resources {
        cpu        = 700
        memory     = 512
        memory_max = 1024
      }
    }

    task "ingester" {
      driver = "docker"

      config {
        image        = "signoz/signoz-otel-collector@sha256:6d1a59bc553e041014597eff0970608948c5c7447aaa984c4d109f2bc9f4062c"
        force_pull   = true
        entrypoint   = ["/bin/sh"]
        args         = ["-ec", "until /signoz-otel-collector migrate sync check; do sleep 5; done; exec /signoz-otel-collector --config=/local/ingester.yaml"]
        ports        = ["otlp-grpc", "otlp-http"]
      }

      env {
        SIGNOZ_OTEL_COLLECTOR_CLICKHOUSE_DSN = "tcp://10.64.0.2:9000"
        SIGNOZ_OTEL_COLLECTOR_TIMEOUT        = "10m"
      }

      template {
        destination = "local/ingester.yaml"
        change_mode = "restart"
        perms       = "0444"
        data        = <<-EOH
        connectors:
          signozmeter:
            dimensions:
            - name: service.name
            - name: deployment.environment
            - name: host.name
            metrics_flush_interval: 1h
        exporters:
          clickhouselogsexporter:
            dsn: tcp://10.64.0.2:9000/signoz_logs
            sending_queue:
              enabled: false
            timeout: 45s
            use_new_schema: true
          clickhousetraces:
            datasource: tcp://10.64.0.2:9000/signoz_traces
            low_cardinal_exception_grouping: false
            sending_queue:
              enabled: false
            timeout: 45s
            use_new_schema: true
          metadataexporter:
            cache:
              provider: in_memory
            dsn: tcp://10.64.0.2:9000/signoz_metadata
            enabled: true
            timeout: 45s
          signozclickhousemeter:
            dsn: tcp://10.64.0.2:9000/signoz_meter
            sending_queue:
              enabled: false
            timeout: 45s
          signozclickhousemetrics:
            dsn: tcp://10.64.0.2:9000/signoz_metrics
            sending_queue:
              enabled: false
            timeout: 45s
        extensions:
          signoz_health_check:
            endpoint: 0.0.0.0:13133
        processors:
          batch:
            send_batch_max_size: 4096
            send_batch_size: 2048
            timeout: 5s
          batch/meter:
            send_batch_max_size: 2048
            send_batch_size: 1024
            timeout: 5s
          memory_limiter:
            check_interval: 5s
            limit_mib: 1600
            spike_limit_mib: 300
          tail_sampling:
            decision_wait: 30s
            expected_new_traces_per_sec: 50
            num_traces: 20000
            sample_on_first_match: true
            policies:
            - name: keep-errors
              type: status_code
              status_code:
                status_codes:
                - ERROR
            - name: sample-success
              type: probabilistic
              probabilistic:
                sampling_percentage: 1
          signozspanmetrics/delta:
            aggregation_temporality: AGGREGATION_TEMPORALITY_DELTA
            dimensions:
            - default: default
              name: service.namespace
            - default: default
              name: deployment.environment
            - name: signoz.collector.id
            - name: service.version
            dimensions_cache_size: 100000
            enable_exp_histogram: true
            latency_histogram_buckets:
            - 100us
            - 1ms
            - 2ms
            - 6ms
            - 10ms
            - 50ms
            - 100ms
            - 250ms
            - 500ms
            - 1000ms
            - 1400ms
            - 2000ms
            - 5s
            - 10s
            - 20s
            - 40s
            - 60s
            metrics_exporter: signozclickhousemetrics
            metrics_flush_interval: 60s
        receivers:
          otlp:
            protocols:
              grpc:
                endpoint: 0.0.0.0:4317
              http:
                endpoint: 0.0.0.0:4318
        service:
          extensions:
          - signoz_health_check
          pipelines:
            logs:
              exporters:
              - clickhouselogsexporter
              - signozmeter
              - metadataexporter
              processors:
              - memory_limiter
              - batch
              receivers:
              - otlp
            metrics:
              exporters:
              - signozclickhousemetrics
              - signozmeter
              - metadataexporter
              processors:
              - memory_limiter
              - batch
              receivers:
              - otlp
            metrics/meter:
              exporters:
              - signozclickhousemeter
              processors:
              - memory_limiter
              - batch/meter
              receivers:
              - signozmeter
            traces:
              exporters:
              - clickhousetraces
              - signozmeter
              - metadataexporter
              processors:
              - memory_limiter
              - signozspanmetrics/delta
              - tail_sampling
              - batch
              receivers:
              - otlp
          telemetry:
            logs:
              encoding: json
            metrics:
              level: basic
              readers:
              - pull:
                  exporter:
                    prometheus:
                      host: 127.0.0.1
                      port: 8888
        EOH
      }

      service {
        name         = "signoz-otlp"
        port         = "otlp-grpc"
        provider     = "nomad"
        address_mode = "host"

        check {
          name     = "signoz-otlp-health"
          type     = "tcp"
          port     = "otlp-grpc"
          interval = "15s"
          timeout  = "5s"
        }
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 2048
      }
    }
  }
}
