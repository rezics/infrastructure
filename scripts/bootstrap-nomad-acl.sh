#!/usr/bin/env bash

set -euo pipefail
umask 077

if [[ "$(id -u)" != 0 ]]; then
	printf '%s\n' "bootstrap-nomad-acl.sh must run as root" >&2
	exit 64
fi

readonly management_token_file=/root/.config/nomad/management.token
if [[ -e "${management_token_file}" ]]; then
	printf 'Management token file already exists: %s\n' "${management_token_file}" >&2
	exit 1
fi

export NOMAD_ADDR=https://127.0.0.1:4646
export NOMAD_CACERT=/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem
export NOMAD_CLIENT_CERT=/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem
export NOMAD_CLIENT_KEY=/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem
export NOMAD_TLS_SERVER_NAME=server.global.nomad

bootstrap_response="$(nomad acl bootstrap -json)"
readonly bootstrap_response
management_token="$(jq -er '.SecretID' <<<"${bootstrap_response}")"
readonly management_token

install -d -o root -g root -m 0700 /root/.config/nomad
printf '%s\n' "${management_token}" >"${management_token_file}"
chmod 0600 "${management_token_file}"
export NOMAD_TOKEN="${management_token}"

nomad namespace apply -description "REZICS production workloads" rezics
nomad namespace apply \
	-description "REZICS production stateful infrastructure" \
	rezics-infrastructure

policy_directory="$(mktemp -d)"
readonly policy_directory
trap 'rm -rf "${policy_directory}"' EXIT

cat >"${policy_directory}/deploy.hcl" <<'EOF'
namespace "rezics" {
  capabilities = [
    "list-jobs",
    "parse-job",
    "read-job",
    "read-logs",
    "submit-job",
  ]
}

EOF

cat >"${policy_directory}/infrastructure.hcl" <<'EOF'
namespace "rezics" {
  capabilities = [
    "list-jobs",
    "parse-job",
    "read-job",
    "read-logs",
    "submit-job",
  ]
}

namespace "rezics-infrastructure" {
  capabilities = [
    "list-jobs",
    "parse-job",
    "read-job",
    "read-logs",
    "submit-job",
  ]
}

host_volume "rezics-*" {
  policy = "write"
}
EOF

cat >"${policy_directory}/application-runtime.hcl" <<'EOF'
namespace "rezics" {
  variables {
    path "application/runtime" {
      capabilities = ["list", "read"]
    }
  }
}
EOF

cat >"${policy_directory}/database-operations.hcl" <<'EOF'
namespace "rezics" {
  variables {
    path "database/operations" {
      capabilities = ["list", "read"]
    }
  }
}
EOF

cat >"${policy_directory}/databasus-runtime.hcl" <<'EOF'
namespace "rezics-infrastructure" {
  variables {
    path "database/databasus-control" {
      capabilities = ["read"]
    }
    path "database/databasus-source" {
      capabilities = ["read"]
    }
  }
}
EOF

cat >"${policy_directory}/databasus-verification-agent.hcl" <<'EOF'
namespace "rezics-infrastructure" {
  variables {
    path "database/databasus-verification-agent" {
      capabilities = ["read"]
    }
  }
}
EOF

cat >"${policy_directory}/databasus-control-backup.hcl" <<'EOF'
namespace "rezics-infrastructure" {
  variables {
    path "database/databasus-control" {
      capabilities = ["read"]
    }
    path "database/databasus-control-backup" {
      capabilities = ["read"]
    }
  }
}
EOF

cat >"${policy_directory}/outline-runtime.hcl" <<'EOF'
namespace "default" {
  variables {
    path "nomad/jobs/outline" {
      capabilities = ["read"]
    }
  }
}
EOF

cat >"${policy_directory}/signoz-runtime.hcl" <<'EOF'
namespace "rezics-infrastructure" {
  variables {
    path "nomad/jobs/signoz-core" {
      capabilities = ["read"]
    }
  }
}
EOF

cat >"${policy_directory}/traefik.hcl" <<'EOF'
namespace "default" {
  capabilities = ["list-jobs", "read-job"]
}

namespace "rezics" {
  capabilities = ["list-jobs", "read-job"]
}

namespace "rezics-infrastructure" {
  capabilities = ["list-jobs", "read-job"]
}
EOF

nomad acl policy apply \
	-description "Deploy and inspect REZICS workloads" \
	rezics-deploy "${policy_directory}/deploy.hcl"
nomad acl policy apply \
	-description "Apply reviewed REZICS stateful infrastructure" \
	rezics-infrastructure "${policy_directory}/infrastructure.hcl"
nomad acl policy apply \
	-description "Discover healthy REZICS services" \
	rezics-traefik "${policy_directory}/traefik.hcl"
for job_id in rezics-api rezics-worker; do
	nomad acl policy apply \
		-description "Read the shared REZICS application runtime" \
		-namespace rezics -job "${job_id}" \
		"${job_id}-application-runtime" \
		"${policy_directory}/application-runtime.hcl"
done

for job_id in \
	rezics-database-install \
	rezics-database-preflight \
	rezics-database-migrate \
	rezics-database-verify \
	rezics-database-project \
	rezics-search-index; do
	nomad acl policy apply \
		-description "Read the shared REZICS database-operation runtime" \
		-namespace rezics -job "${job_id}" \
		"${job_id}-runtime" "${policy_directory}/database-operations.hcl"
done

nomad acl policy apply \
	-description "Read only Databasus control and source variables" \
	-namespace rezics-infrastructure -job rezics-databasus -group databasus -task databasus \
	rezics-databasus-runtime "${policy_directory}/databasus-runtime.hcl"
nomad acl policy apply \
	-description "Read only the Databasus verification-agent identity" \
	-namespace rezics-infrastructure -job rezics-databasus-verification-agent \
	-group verification-agent -task verification-agent \
	rezics-databasus-verification-agent "${policy_directory}/databasus-verification-agent.hcl"
nomad acl policy apply \
	-description "Read only the Databasus cold-backup credentials" \
	-namespace rezics-infrastructure -job rezics-databasus-control-backup \
	-group backup -task backup \
	rezics-databasus-control-backup "${policy_directory}/databasus-control-backup.hcl"
nomad acl policy apply \
	-description "Read the Outline runtime from the database task" \
	-namespace default -job outline-postgres -group postgres -task postgres \
	outline-postgres-runtime "${policy_directory}/outline-runtime.hcl"
nomad acl policy apply \
	-description "Read the Outline runtime from the application task" \
	-namespace default -job outline-app -group outline -task outline \
	outline-app-runtime "${policy_directory}/outline-runtime.hcl"
nomad acl policy apply \
	-description "Read only the SigNoz signing runtime" \
	-namespace rezics-infrastructure -job signoz-core -group core -task signoz \
	signoz-core-runtime "${policy_directory}/signoz-runtime.hcl"

deploy_token="$(
	nomad acl token create -name "REZICS production deploy" -policy rezics-deploy -json |
		jq -er '.SecretID'
)"
readonly deploy_token
infrastructure_token="$(
	nomad acl token create \
		-name "REZICS production infrastructure" \
		-policy rezics-infrastructure -json |
		jq -er '.SecretID'
)"
readonly infrastructure_token
traefik_token="$(
	nomad acl token create -name "REZICS Traefik discovery" -policy rezics-traefik -json |
		jq -er '.SecretID'
)"
readonly traefik_token

printf '%s\n' "${deploy_token}" >/var/lib/rezics-deploy/nomad.token
chown rezics-deploy:rezics-deploy /var/lib/rezics-deploy/nomad.token
chmod 0600 /var/lib/rezics-deploy/nomad.token

printf '%s\n' "${infrastructure_token}" \
	>/var/lib/rezics-infrastructure-deploy/nomad.token
chown rezics-infrastructure-deploy:rezics-infrastructure-deploy \
	/var/lib/rezics-infrastructure-deploy/nomad.token
chmod 0600 /var/lib/rezics-infrastructure-deploy/nomad.token

printf '%s\n' \
	"TRAEFIK_PROVIDERS_NOMAD_ENDPOINT_TOKEN=${traefik_token}" \
	"NOMAD_TOKEN=${traefik_token}" \
	>/var/lib/traefik/nomad.env
chown traefik:traefik /var/lib/traefik/nomad.env
chmod 0600 /var/lib/traefik/nomad.env

systemctl restart traefik.service
printf '%s\n' \
	"Nomad ACLs, namespaces, and scoped deploy, infrastructure, and service tokens are ready."
