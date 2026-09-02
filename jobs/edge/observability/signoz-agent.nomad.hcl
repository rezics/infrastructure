job "signoz-agent" {
  namespace   = "rezics-infrastructure"
  datacenters = ["dc1"]
  type        = "service"

  group "edge" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "edge"
    }

    network {
      mode = "host"
    }

    task "collector" {
      driver = "docker"
      user   = "0"

      config {
        image        = "otel/opentelemetry-collector-contrib@sha256:45392d534c1edcc809c2d112394029246bc679d2ae5ea7081414a1fc74f2c621"
        force_pull   = true
        network_mode = "host"
        args         = ["--config=/local/agent.yaml"]
        mount {
          type      = "bind"
          source    = "/"
          target    = "/hostfs"
          readonly = true
        }
        mount {
          type      = "bind"
          source    = "/var/run/docker.sock"
          target    = "/var/run/docker.sock"
          readonly = true
        }
      }

      template {
        destination = "local/agent.yaml"
        change_mode = "restart"
        perms       = "0444"
        data        = <<-EOH
        receivers:
          docker_stats:
            endpoint: unix:///var/run/docker.sock
            api_version: "1.40"
            collection_interval: 60s
          hostmetrics:
            collection_interval: 60s
            root_path: /hostfs
            scrapers:
              cpu: {}
              disk: {}
              filesystem:
                exclude_mount_points:
                  match_type: regexp
                  mount_points:
                  - /hostfs/(proc|sys|dev|run)($|/)
              load: {}
              memory: {}
              network: {}
          prometheus/nomad:
            config:
              scrape_configs:
              - job_name: nomad
                metrics_path: /v1/metrics
                params:
                  format: [prometheus]
                scheme: https
                scrape_interval: 60s
                static_configs:
                - targets: [127.0.0.1:4646]
                tls_config:
                  ca_file: /hostfs/var/lib/nomad/tls/nomad-agent-ca.pem
                  cert_file: /hostfs/var/lib/nomad/tls/global-server-nomad.pem
                  key_file: /hostfs/var/lib/nomad/tls/global-server-nomad-key.pem
                  server_name: server.global.nomad
        processors:
          batch:
            send_batch_size: 256
            timeout: 10s
          memory_limiter:
            check_interval: 5s
            limit_mib: 200
            spike_limit_mib: 40
          resource/host:
            attributes:
            - action: upsert
              key: host.name
              value: A
            - action: upsert
              key: host.id
              value: rezics-A
            - action: upsert
              key: service.name
              value: rezics-host-health
            - action: upsert
              key: service.namespace
              value: rezics-infrastructure
            - action: upsert
              key: deployment.environment.name
              value: production
          resource/nomad:
            attributes:
            - action: upsert
              key: host.name
              value: A
            - action: upsert
              key: host.id
              value: rezics-A
            - action: upsert
              key: service.name
              value: nomad
            - action: upsert
              key: service.namespace
              value: rezics-infrastructure
            - action: upsert
              key: deployment.environment.name
              value: production
        exporters:
          otlp:
            endpoint: 10.64.0.1:4317
            tls:
              insecure: true
        service:
          pipelines:
            metrics/host:
              receivers: [hostmetrics, docker_stats]
              processors: [memory_limiter, resource/host, batch]
              exporters: [otlp]
            metrics/nomad:
              receivers: [prometheus/nomad]
              processors: [memory_limiter, resource/nomad, batch]
              exporters: [otlp]
          telemetry:
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

      resources {
        cpu        = 150
        memory     = 256
        memory_max = 512
      }
    }
  }

  group "data" {
    count = 1

    constraint {
      attribute = "${meta.role}"
      operator  = "="
      value     = "data"
    }

    network {
      mode = "host"
    }

    task "collector" {
      driver = "docker"
      user   = "0"

      config {
        image        = "otel/opentelemetry-collector-contrib@sha256:45392d534c1edcc809c2d112394029246bc679d2ae5ea7081414a1fc74f2c621"
        force_pull   = true
        network_mode = "host"
        args         = ["--config=/local/agent.yaml"]
        mount {
          type      = "bind"
          source    = "/"
          target    = "/hostfs"
          readonly = true
        }
        mount {
          type      = "bind"
          source    = "/var/run/docker.sock"
          target    = "/var/run/docker.sock"
          readonly = true
        }
      }

      template {
        destination = "secrets/runtime.env"
        env         = true
        change_mode = "restart"
        perms       = "0400"
        data        = <<-EOH
        {{- with nomadVar "nomad/jobs/signoz-agent" -}}
        POSTGRES_USERNAME={{ .POSTGRES_USERNAME | toJSON }}
        POSTGRES_PASSWORD={{ .POSTGRES_PASSWORD | toJSON }}
        {{- end }}
        EOH
      }

      template {
        destination = "local/agent.yaml"
        change_mode = "restart"
        perms       = "0444"
        data        = <<-EOH
        receivers:
          docker_stats:
            endpoint: unix:///var/run/docker.sock
            api_version: "1.40"
            collection_interval: 60s
          hostmetrics:
            collection_interval: 60s
            root_path: /hostfs
            scrapers:
              cpu: {}
              disk: {}
              filesystem:
                exclude_mount_points:
                  match_type: regexp
                  mount_points:
                  - /hostfs/(proc|sys|dev|run)($|/)
              load: {}
              memory: {}
              network: {}
          postgresql:
            endpoint: 10.64.0.2:5432
            transport: tcp
            username: $${env:POSTGRES_USERNAME}
            password: $${env:POSTGRES_PASSWORD}
            databases: [rezics]
            collection_interval: 60s
            metrics:
              postgresql.deadlocks:
                enabled: true
            tls:
              insecure: true
          prometheus/nomad:
            config:
              scrape_configs:
              - job_name: nomad
                metrics_path: /v1/metrics
                params:
                  format: [prometheus]
                scheme: https
                scrape_interval: 60s
                static_configs:
                - targets: [127.0.0.1:4646]
                tls_config:
                  ca_file: /hostfs/var/lib/nomad/tls/nomad-agent-ca.pem
                  cert_file: /hostfs/var/lib/nomad/tls/global-server-nomad.pem
                  key_file: /hostfs/var/lib/nomad/tls/global-server-nomad-key.pem
                  server_name: server.global.nomad
        processors:
          batch:
            send_batch_size: 256
            timeout: 10s
          memory_limiter:
            check_interval: 5s
            limit_mib: 200
            spike_limit_mib: 40
          resource/host:
            attributes:
            - action: upsert
              key: host.name
              value: B
            - action: upsert
              key: host.id
              value: rezics-B
            - action: upsert
              key: service.name
              value: rezics-host-health
            - action: upsert
              key: service.namespace
              value: rezics-infrastructure
            - action: upsert
              key: deployment.environment.name
              value: production
          resource/nomad:
            attributes:
            - action: upsert
              key: host.name
              value: B
            - action: upsert
              key: host.id
              value: rezics-B
            - action: upsert
              key: service.name
              value: nomad
            - action: upsert
              key: service.namespace
              value: rezics-infrastructure
            - action: upsert
              key: deployment.environment.name
              value: production
          resource/postgresql:
            attributes:
            - action: upsert
              key: host.name
              value: B
            - action: upsert
              key: host.id
              value: rezics-B
            - action: upsert
              key: service.name
              value: rezics-postgres
            - action: upsert
              key: service.namespace
              value: rezics
            - action: upsert
              key: deployment.environment.name
              value: production
        exporters:
          otlp:
            endpoint: 10.64.0.1:4317
            tls:
              insecure: true
        service:
          pipelines:
            metrics/host:
              receivers: [hostmetrics, docker_stats]
              processors: [memory_limiter, resource/host, batch]
              exporters: [otlp]
            metrics/nomad:
              receivers: [prometheus/nomad]
              processors: [memory_limiter, resource/nomad, batch]
              exporters: [otlp]
            metrics/postgresql:
              receivers: [postgresql]
              processors: [memory_limiter, resource/postgresql, batch]
              exporters: [otlp]
          telemetry:
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

      resources {
        cpu        = 150
        memory     = 256
        memory_max = 512
      }
    }
  }
}
