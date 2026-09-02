#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly management_token_file=/root/.config/nomad/management.token
readonly release_job_file="${REZICS_RELEASE_JOB_FILE:?}"
readonly build_job_file="${REZICS_RELEASE_BUILD_JOB_FILE:?}"
readonly database_job_file="${REZICS_RELEASE_DATABASE_JOB_FILE:?}"
readonly maintenance_release_job_file="${REZICS_RELEASE_MAINTENANCE_JOB_FILE:?}"
readonly api_deploy_job_file="${REZICS_RELEASE_API_DEPLOY_JOB_FILE:?}"
readonly worker_deploy_job_file="${REZICS_RELEASE_WORKER_DEPLOY_JOB_FILE:?}"
readonly projection_job_file="${REZICS_RELEASE_PROJECTION_JOB_FILE:?}"
readonly maintenance_service_job_file="${REZICS_API_MAINTENANCE_JOB_FILE:?}"
readonly gateway_admin_token_file="${REZICS_GATEWAY_ADMIN_TOKEN_FILE:?}"
readonly -a release_job_files=(
	"${release_job_file}"
	"${build_job_file}"
	"${database_job_file}"
	"${maintenance_release_job_file}"
	"${api_deploy_job_file}"
	"${worker_deploy_job_file}"
	"${projection_job_file}"
)

for required_file in \
	"${management_token_file}" \
	"${release_job_files[@]}" \
	"${maintenance_service_job_file}" \
	"${gateway_admin_token_file}"; do
	if [[ ! -r "${required_file}" ]]; then
		printf 'Required delivery input is missing: %s\n' "${required_file}" >&2
		exit 1
	fi
done

export NOMAD_ADDR=https://127.0.0.1:4646
export NOMAD_CACERT=/var/lib/rezics-deploy/nomad-tls/nomad-agent-ca.pem
export NOMAD_CLIENT_CERT=/var/lib/rezics-deploy/nomad-tls/global-cli-nomad.pem
export NOMAD_CLIENT_KEY=/var/lib/rezics-deploy/nomad-tls/global-cli-nomad-key.pem
export NOMAD_TLS_SERVER_NAME=server.global.nomad
NOMAD_TOKEN="$(<"${management_token_file}")"
export NOMAD_TOKEN

nomad_ready=false
for _attempt in $(seq 1 30); do
	if nomad status >/dev/null 2>&1; then
		nomad_ready=true
		break
	fi
	sleep 1
done
if [[ "${nomad_ready}" != true ]]; then
	printf 'Nomad API did not become ready within 30 seconds\n' >&2
	exit 1
fi

temporary_directory="$(mktemp -d)"
cleanup() {
	rm -rf "${temporary_directory}"
}
trap cleanup EXIT

nomad namespace apply -description "Protected REZICS release workloads" rezics-release

cat >"${temporary_directory}/release-dispatch.hcl" <<'EOF'
namespace "rezics-release" {
  capabilities = ["dispatch-job"]
}
EOF

cat >"${temporary_directory}/release-controller.hcl" <<'EOF'
namespace "rezics-release" {
  capabilities = ["dispatch-job", "list-jobs", "read-job", "read-logs"]
}
EOF

cat >"${temporary_directory}/release-database-variable.hcl" <<'EOF'
namespace "rezics-release" {
  variables {
    path "release/database" {
      capabilities = ["list", "read"]
    }
  }
}
EOF

cat >"${temporary_directory}/databasus-runtime.hcl" <<'EOF'
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

cat >"${temporary_directory}/databasus-verification-agent.hcl" <<'EOF'
namespace "rezics-infrastructure" {
  variables {
    path "database/databasus-verification-agent" {
      capabilities = ["read"]
    }
  }
}
EOF

cat >"${temporary_directory}/databasus-control-backup.hcl" <<'EOF'
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

cat >"${temporary_directory}/outline-runtime.hcl" <<'EOF'
namespace "default" {
  variables {
    path "nomad/jobs/outline" {
      capabilities = ["read"]
    }
  }
}
EOF

cat >"${temporary_directory}/signoz-runtime.hcl" <<'EOF'
namespace "rezics-infrastructure" {
  variables {
    path "nomad/jobs/signoz-core" {
      capabilities = ["read"]
    }
  }
}
EOF

cat >"${temporary_directory}/admin-portal.hcl" <<'EOF'
namespace "default" {
  capabilities = ["list-jobs", "read-job", "read-logs"]
}

namespace "rezics" {
  capabilities = ["list-jobs", "read-job", "read-logs"]
}

namespace "rezics-infrastructure" {
  capabilities = ["list-jobs", "read-job", "read-logs"]
}

namespace "rezics-release" {
  capabilities = ["list-jobs", "read-job", "read-logs"]
}

agent {
  policy = "read"
}

node {
  policy = "read"
}

plugin {
  policy = "read"
}

quota {
  policy = "read"
}

host_volume "*" {
  policy = "read"
}
EOF

nomad acl policy apply \
	-description "Dispatch only the fixed REZICS release parent job through the gateway" \
	rezics-github-release-dispatch "${temporary_directory}/release-dispatch.hcl"
nomad acl policy apply \
	-description "Coordinate fixed component release jobs" \
	-namespace rezics-release -job rezics-release -group controller -task controller \
	rezics-release-controller "${temporary_directory}/release-controller.hcl"
nomad acl policy apply \
	-description "Read database operation credentials from the database release task" \
	-namespace rezics-release -job rezics-release-database -group database -task database \
	rezics-release-database-variable "${temporary_directory}/release-database-variable.hcl"
nomad acl policy apply \
	-description "Read database operation credentials from the projection release task" \
	-namespace rezics-release -job rezics-release-projection -group projection -task projection \
	rezics-release-projection-variable "${temporary_directory}/release-database-variable.hcl"
nomad acl policy apply \
	-description "Read only Databasus control and source variables" \
	-namespace rezics-infrastructure -job rezics-databasus -group databasus -task databasus \
	rezics-databasus-runtime "${temporary_directory}/databasus-runtime.hcl"
nomad acl policy apply \
	-description "Read only the Databasus verification-agent identity" \
	-namespace rezics-infrastructure -job rezics-databasus-verification-agent \
	-group verification-agent -task verification-agent \
	rezics-databasus-verification-agent "${temporary_directory}/databasus-verification-agent.hcl"
nomad acl policy apply \
	-description "Read only the Databasus cold-backup credentials" \
	-namespace rezics-infrastructure -job rezics-databasus-control-backup \
	-group backup -task backup \
	rezics-databasus-control-backup "${temporary_directory}/databasus-control-backup.hcl"
nomad acl policy apply \
	-description "Read the Outline runtime from the database task" \
	-namespace default -job outline-postgres -group postgres -task postgres \
	outline-postgres-runtime "${temporary_directory}/outline-runtime.hcl"
nomad acl policy apply \
	-description "Read the Outline runtime from the application task" \
	-namespace default -job outline-app -group outline -task outline \
	outline-app-runtime "${temporary_directory}/outline-runtime.hcl"
nomad acl policy apply \
	-description "Read only the SigNoz signing runtime" \
	-namespace rezics-infrastructure -job signoz-core -group core -task signoz \
	signoz-core-runtime "${temporary_directory}/signoz-runtime.hcl"
nomad acl policy apply \
	-description "Inspect jobs through the protected portal without mutation rights" \
	rezics-admin-portal "${temporary_directory}/admin-portal.hcl"

cat >"${temporary_directory}/github-release.json" <<'EOF'
{
  "JWKSURL": "https://token.actions.githubusercontent.com/.well-known/jwks",
  "BoundAudiences": ["rezics-nomad-release"],
  "BoundIssuer": ["https://token.actions.githubusercontent.com"],
  "SigningAlgs": ["RS256"],
  "ExpirationLeeway": "1m",
  "NotBeforeLeeway": "1m",
  "ClockSkewLeeway": "1m",
  "ClaimMappings": {
    "environment": "environment",
    "event_name": "event_name",
    "ref": "ref",
    "ref_type": "ref_type",
    "repository": "repository",
    "repository_id": "repository_id",
    "repository_owner_id": "repository_owner_id",
    "run_attempt": "run_attempt",
    "run_id": "run_id",
    "runner_environment": "runner_environment",
    "sha": "sha",
    "workflow_ref": "workflow_ref"
  }
}
EOF

if nomad acl auth-method info -json github-release >/dev/null 2>&1; then
	nomad acl auth-method update \
		-type JWT \
		-max-token-ttl 5m \
		-token-locality global \
		-token-name-format "github-release-\${value.run_id}-\${value.run_attempt}" \
		-config "@${temporary_directory}/github-release.json" \
		github-release >/dev/null
else
	nomad acl auth-method create \
		-name github-release \
		-type JWT \
		-max-token-ttl 5m \
		-token-locality global \
		-token-name-format "github-release-\${value.run_id}-\${value.run_attempt}" \
		-config "@${temporary_directory}/github-release.json" >/dev/null
fi

apply_binding_rule() {
	local auth_method="$1"
	local description="$2"
	local bind_name="$3"
	local selector="$4"
	local binding_rule_id
	mapfile -t binding_rule_ids < <(
		nomad acl binding-rule list -json |
			jq -r --arg auth_method "${auth_method}" \
				'.[] | select(.AuthMethod == $auth_method) | .ID'
	)
	if ((${#binding_rule_ids[@]} > 1)); then
		printf 'Expected at most one binding rule for %s, found %s\n' \
			"${auth_method}" "${#binding_rule_ids[@]}" >&2
		exit 1
	fi
	if ((${#binding_rule_ids[@]} == 1)); then
		binding_rule_id="${binding_rule_ids[0]}"
		nomad acl binding-rule update \
			-description "${description}" \
			-selector "${selector}" \
			-bind-type policy \
			-bind-name "${bind_name}" \
			"${binding_rule_id}" >/dev/null
	else
		nomad acl binding-rule create \
			-description "${description}" \
			-auth-method "${auth_method}" \
			-selector "${selector}" \
			-bind-type policy \
			-bind-name "${bind_name}" >/dev/null
	fi
}

readonly release_selector='value.repository_id == "994100138" and value.repository_owner_id == "92638361" and value.repository == "rezics/rezics" and value.runner_environment == "github-hosted" and value.environment == "production" and value.workflow_ref matches "^rezics/rezics/.github/workflows/release\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$" and value.event_name == "push" and value.ref_type == "tag" and value.ref matches "^refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+$"'
apply_binding_rule \
	github-release \
	"Protected production environment, immutable REZICS identity, and stable semantic tag" \
	rezics-github-release-dispatch \
	"${release_selector}"

for job_file in "${release_job_files[@]}"; do
	nomad job validate -namespace=rezics-release "${job_file}" >/dev/null
	nomad job run -namespace=rezics-release -detach "${job_file}" >/dev/null
done

nomad job validate -namespace=rezics "${maintenance_service_job_file}" >/dev/null
nomad job run -namespace=rezics -detach "${maintenance_service_job_file}" >/dev/null

database_variable="${temporary_directory}/database-variable.json"
curl --fail --silent --show-error \
	--header "X-Nomad-Token: ${NOMAD_TOKEN}" \
	--cacert "${NOMAD_CACERT}" \
	--cert "${NOMAD_CLIENT_CERT}" \
	--key "${NOMAD_CLIENT_KEY}" \
	"${NOMAD_ADDR}/v1/var/database/operations?namespace=rezics" \
	>"${database_variable}"
jq -e '
	(.Items | type == "object") and
	(.Items.DATABASE_URL | type == "string" and length > 0) and
	(.Items.DATABASE_ADMIN_URL | type == "string" and length > 0)
' "${database_variable}" >/dev/null
jq '{Namespace: "rezics-release", Path: "release/database", Items: .Items}' \
	"${database_variable}" |
	curl --fail --silent --show-error \
		--request PUT \
		--header "X-Nomad-Token: ${NOMAD_TOKEN}" \
		--header "Content-Type: application/json" \
		--cacert "${NOMAD_CACERT}" \
		--cert "${NOMAD_CLIENT_CERT}" \
		--key "${NOMAD_CLIENT_KEY}" \
		--data-binary @- \
		"${NOMAD_ADDR}/v1/var/release/database?namespace=rezics-release" >/dev/null

gateway_token_curl_config="${temporary_directory}/gateway-token.curl"
printf 'header = "X-Nomad-Token: %s"\n' \
	"$(<"${gateway_admin_token_file}")" >"${gateway_token_curl_config}"
chmod 0600 "${gateway_token_curl_config}"
if ! curl --fail --silent --show-error \
	--config "${gateway_token_curl_config}" \
	--cacert "${NOMAD_CACERT}" \
	--cert "${NOMAD_CLIENT_CERT}" \
	--key "${NOMAD_CLIENT_KEY}" \
	"${NOMAD_ADDR}/v1/acl/token/self" |
	jq -e '.Type == "client" and (.Policies | index("rezics-admin-portal")) != null' >/dev/null; then
	printf '%s\n' "Gateway admin proxy token does not have the expected portal policy" >&2
	exit 1
fi

printf '%s\n' \
	"REZICS release OIDC, maintenance fallback, component jobs, and scoped variables are reconciled"
