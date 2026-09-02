job "webhook" {
  type = "service"

  group "webhook" {
    count = 1

    network {
      port "http" {
        static       = 9000
        to           = 9000
        host_network = "loopback"
      }
    }

    service {
      name     = "webhook"
      port     = "http"
      provider = "nomad"
    }

    task "webhook" {
      driver = "docker"

      config {
        image = "almir/webhook@sha256:d37e58941b7997d2c324d70e9e5b49d5d26769a92f0260a1c201782dacd4787a"
        ports = ["http"]
        args  = ["-verbose", "-hooks", "/etc/webhook/hooks.json", "-hotreload"]
        volumes = [
          "local/hooks.json:/etc/webhook/hooks.json",
        ]
      }

      template {
        data = <<-EOH
[
  {
    "id": "hello",
    "execute-command": "/bin/echo",
    "command-working-directory": "/tmp",
    "pass-arguments-to-command": [
      { "source": "string", "name": "Hello from webhook!" }
    ],
    "response-message": "Hook executed successfully.\n"
  }
]
        EOH
        destination = "local/hooks.json"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
