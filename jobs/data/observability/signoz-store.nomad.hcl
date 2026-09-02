job "signoz-store" {
  namespace   = "rezics-infrastructure"
  datacenters = ["dc1"]
  type        = "service"

  group "store" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "data"
    }

    network {
      mode = "host"

      port "clickhouse" {
        static       = 9000
        host_network = "wireguard"
      }

      port "clickhouse-http" {
        static       = 8123
        host_network = "wireguard"
      }
    }

    volume "clickhouse" {
      type      = "host"
      source    = "signoz-clickhouse"
      read_only = false
    }

    volume "keeper" {
      type      = "host"
      source    = "signoz-keeper"
      read_only = false
    }

    volume "user-scripts" {
      type      = "host"
      source    = "signoz-clickhouse-user-scripts"
      read_only = false
    }

    task "keeper" {
      driver = "docker"

      config {
        image        = "clickhouse/clickhouse-keeper@sha256:525b8b0f93ccb371131c46f22a066ea43d33d74aba314203e8044609945d8524"
        force_pull   = true
        network_mode = "host"
        entrypoint   = ["/usr/bin/clickhouse-keeper"]
        args         = ["--config-file=/local/keeper.yaml"]
      }

      template {
        destination = "local/keeper.yaml"
        change_mode = "restart"
        perms       = "0444"
        data        = <<-EOH
        keeper_server:
          coordination_settings:
            force_sync: false
            operation_timeout_ms: 10000
            raft_logs_level: warning
            session_timeout_ms: 30000
            snapshot_distance: 100000
            snapshots_to_keep: 3
          four_letter_word_white_list: '*'
          log_storage_path: /var/lib/clickhouse-keeper/coordination/log
          raft_configuration:
            server:
            - hostname: 127.0.0.1
              id: 0
              port: 9234
          server_id: 0
          snapshot_storage_path: /var/lib/clickhouse-keeper/coordination/snapshots
          tcp_port: 9181
        listen_host: 127.0.0.1
        logger:
          console: true
          level: information
        EOH
      }

      volume_mount {
        volume      = "keeper"
        destination = "/var/lib/clickhouse-keeper"
        read_only   = false
      }

      resources {
        cpu        = 250
        memory     = 256
        memory_max = 512
      }
    }

    task "clickhouse" {
      driver = "docker"

      config {
        image        = "clickhouse/clickhouse-server@sha256:cacf32d6884291dc2ff5e0156a97f46fc53ff7c929a7906d114e268a929dfd3a"
        force_pull   = true
        network_mode = "host"
        command      = "/bin/bash"
        args = [
          "-ec",
          "install -m 0644 /local/functions.yaml /var/lib/clickhouse/user_scripts/functions.yaml; until (echo >/dev/tcp/127.0.0.1/9181) 2>/dev/null; do sleep 2; done; exec clickhouse-server --config-file=/local/clickhouse.yaml",
        ]
      }

      template {
        destination = "local/functions.yaml"
        change_mode = "restart"
        perms       = "0444"
        data        = <<-EOH
        functions:
          argument:
          - name: buckets
            type: Array(Float64)
          - name: counts
            type: Array(Float64)
          - name: quantile
            type: Float64
          command: ./histogramQuantile
          format: CSV
          name: histogramQuantile
          return_type: Float64
          type: executable
        EOH
      }

      template {
        destination = "local/clickhouse.yaml"
        change_mode = "restart"
        perms       = "0444"
        data        = <<-EOH
        dictionaries_config: '*_dictionary.xml'
        display_name: rezics-signoz
        distributed_ddl:
          path: /clickhouse/task_queue/ddl
        error_log:
          ttl: event_date + INTERVAL 1 DAY DELETE
        format_schema_path: /var/lib/clickhouse/format_schemas/
        http_port: 8123
        interserver_http_port: 9009
        listen_host: 0.0.0.0
        logger:
          console: 1
          count: 10
          formatting:
            type: console
          level: information
          size: 1000M
        macros:
          replica: "00"
          shard: "00"
        metric_log:
          collect_interval_milliseconds: 60000
          flush_interval_milliseconds: 60000
          ttl: event_date + INTERVAL 1 DAY DELETE
        part_log:
          ttl: event_date + INTERVAL 1 DAY DELETE
        profiles:
          default:
            allow_simdjson: 0
            load_balancing: random
            log_queries: 1
            log_queries_min_query_duration_ms: 200
            log_queries_min_type: QUERY_FINISH
            log_query_threads: 0
            log_query_views: 0
            memory_profiler_sample_probability: 0
            memory_profiler_step: 0
            query_profiler_cpu_time_period_ns: 0
            query_profiler_real_time_period_ns: 0
        query_log:
          flush_interval_milliseconds: 60000
          partition_by: toYYYYMM(event_date)
          ttl: event_date + INTERVAL 1 DAY DELETE
        quotas:
          default:
            interval:
              duration: 3600
              errors: 0
              execution_time: 0
              queries: 0
              read_rows: 0
              result_rows: 0
        remote_servers:
          cluster:
            shard:
            - replica:
                host: 10.64.0.2
                port: 9000
        tcp_port: 9000
        user_defined_executable_functions_config: /var/lib/clickhouse/user_scripts/functions.yaml
        user_files_path: /var/lib/clickhouse/user_files/
        user_scripts_path: /var/lib/clickhouse/user_scripts/
        users:
          default:
            access_management: 1
            named_collection_control: 1
            networks:
              ip: ::/0
            password: ""
            profile: default
            quota: default
            show_named_collection: 1
            show_named_collection_secrets: 1
        zookeeper:
          node:
          - host: 127.0.0.1
            port: 9181
        EOH
      }

      volume_mount {
        volume      = "clickhouse"
        destination = "/var/lib/clickhouse"
        read_only   = false
      }

      volume_mount {
        volume      = "user-scripts"
        destination = "/var/lib/clickhouse/user_scripts"
        read_only   = false
      }

      service {
        name         = "signoz-clickhouse"
        port         = "clickhouse-http"
        provider     = "nomad"
        address_mode = "host"

        check {
          name     = "clickhouse-http"
          type     = "http"
          path     = "/ping"
          interval = "15s"
          timeout  = "3s"
        }
      }

      resources {
        cpu        = 2000
        memory     = 2048
        memory_max = 4096
      }
    }

    task "clickhouse-functions" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      config {
        image        = "clickhouse/clickhouse-server@sha256:cacf32d6884291dc2ff5e0156a97f46fc53ff7c929a7906d114e268a929dfd3a"
        force_pull   = true
        network_mode = "host"
        command      = "/bin/bash"
        args = [
          "-ec",
          "if [ ! -x /var/lib/clickhouse/user_scripts/histogramQuantile ]; then for attempt in $(seq 1 30); do command -v wget >/dev/null 2>&1 && wget -q -O /tmp/histogram-quantile.tar.gz https://github.com/SigNoz/signoz/releases/download/histogram-quantile%2Fv0.0.1/histogram-quantile_linux_amd64.tar.gz && tar -xzf /tmp/histogram-quantile.tar.gz -C /tmp && install -m 0755 /tmp/histogram-quantile /var/lib/clickhouse/user_scripts/histogramQuantile && rm -f /tmp/histogram-quantile.tar.gz /tmp/histogram-quantile && break; sleep 2; done; fi; test -x /var/lib/clickhouse/user_scripts/histogramQuantile",
        ]
      }

      volume_mount {
        volume      = "user-scripts"
        destination = "/var/lib/clickhouse/user_scripts"
        read_only   = false
      }

      resources {
        cpu        = 100
        memory     = 128
        memory_max = 256
      }
    }

    task "migrator" {
      driver = "docker"

      lifecycle {
        hook    = "poststart"
        sidecar = false
      }

      config {
        image        = "signoz/signoz-otel-collector@sha256:6d1a59bc553e041014597eff0970608948c5c7447aaa984c4d109f2bc9f4062c"
        force_pull   = true
        network_mode = "host"
        entrypoint   = ["/bin/sh"]
        args = [
          "-ec",
          "until /signoz-otel-collector migrate ready; do sleep 5; done; /signoz-otel-collector migrate bootstrap; /signoz-otel-collector migrate sync up; /signoz-otel-collector migrate async up",
        ]
      }

      env {
        SIGNOZ_OTEL_COLLECTOR_CLICKHOUSE_DSN = "tcp://10.64.0.2:9000"
        SIGNOZ_OTEL_COLLECTOR_TIMEOUT        = "10m"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
