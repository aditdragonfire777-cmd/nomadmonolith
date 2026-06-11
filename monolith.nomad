# This is a Nomad job specification written in HCL (HashiCorp Configuration Language).
# It defines how Nomad should deploy, monitor, and scale our Monolith application.

job "monolith-app" {
  # Specifies the region and datacenter where this job should run.
  datacenters = ["dc1"]
  
  # "service" type is for long-running processes (like web servers or APIs) 
  # that must stay active continuously.
  type = "service"

  # The update stanza defines how Nomad transitions to new versions of the monolith.
  update {
    max_parallel      = 1
    health_decay      = "30s"
    progress_deadline = "10m"
    auto_revert       = true      # Automatically rolls back if the new deployment fails health checks!
  }

  # Groups represent collections of tasks that must run on the exact same server node.
  group "monolith-group" {
    # For a traditional stateful monolith, we typically start with a count of 1 
    # to avoid concurrent database lockups, though we can scale if designed statelessly.
    count = 1

    # Network requirements for the monolith container/process.
    network {
      port "http" {
        # Dynamically map an external port on the host machine to port 8080 inside the container.
        to = 8080
      }
    }

    # VAULT INTEGRATION:
    # Tell Nomad to contact Vault to retrieve temporary access tokens.
    # The task will have access to the policies listed here.
    vault {
      policies = ["monolith-secrets-reader"]
      change_mode = "restart"  # Restart the monolith if credentials/certs are rotated in Vault.
    }

    # The actual task (the program running the monolith).
    task "monolith-server" {
      # We use the Docker driver, but Nomad can also use "exec" for raw binaries or "java" for JAR files.
      driver = "docker"

      config {
        image = "mycompany/monolith-app:v2.4.0"
        ports = ["http"]
      }

      # ENVIRONMENT VARIABLES:
      # Pass basic settings to the monolith.
      env {
        APP_ENV  = "production"
        LOG_LEVEL = "info"
      }

      # TEMPLATING SECRETS (Consul/Vault Integration):
      # This block securely fetches database credentials from Vault at runtime 
      # and writes them to a local config file inside the container.
      template {
        data = <<EOH
# Database Configuration generated dynamically by Nomad & Vault
DB_HOST="postgres-db.service.consul"
DB_PORT=5432
{{ with secret "secret/data/monolith/database" }}
DB_USER="{{ .Data.data.username }}"
DB_PASSWORD="{{ .Data.data.password }}"
{{ end }}
EOH
        destination = "secrets/db_config.env"
        env         = true # Automatically inject these variables into the container environment!
      }

      # CONSUL INTEGRATION (Service Discovery & Routing):
      # Registers the monolith with Consul so users/load balancers can find it.
      service {
        name = "monolith-service"
        tags = ["production", "http"]
        port = "http"

        # Health checks ensure Consul only routes healthy traffic to the monolith.
        check {
          name     = "alive"
          type     = "http"
          path     = "/healthz"
          interval = "10s"
          timeout  = "2s"

          # If the monolith fails this health check repeatedly, Nomad will 
          # declare it dead and spin up a fresh copy on a healthy server.
          check_restart {
            limit = 3
            grace = "60s"
          }
        }
      }

      # RESOURCE ALLOCATION:
      # Monoliths can be resource-heavy, so we explicitly dedicate resources.
      resources {
        cpu    = 2000 # 2000 MHz (equivalent to roughly 2 CPUs)
        memory = 4096 # 4 GB of RAM
      }
    }
  }
}
