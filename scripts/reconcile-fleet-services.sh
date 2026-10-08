#!/usr/bin/env bash
set -euo pipefail
umask 077
export NOMAD_ADDR=https://127.0.0.1:4646 NOMAD_TLS_SERVER_NAME=server.global.nomad
NOMAD_TOKEN="$(<"${FLEET_NOMAD_MANAGEMENT_TOKEN_FILE:?}")"
export NOMAD_TOKEN
for _attempt in $(seq 1 60); do
  if nomad status >/dev/null 2>&1; then break; fi
  sleep 1
done
nomad status >/dev/null

# Retired application jobs must not return on rebuild; retain the backup stack.
while read -r namespace job; do
  if nomad job inspect -namespace="$namespace" -json "$job" >/dev/null 2>&1; then
    nomad job stop -namespace="$namespace" -detach -purge "$job" >/dev/null
    printf 'Retired %s/%s\n' "$namespace" "$job"
  fi
done <<'JOBS'
rezics rezics-api
rezics rezics-worker
rezics rezics-api-maintenance
rezics-infrastructure rezics-pgbouncer
rezics-infrastructure rezics-postgres
rezics-infrastructure signoz-agent
rezics-infrastructure signoz-core
rezics-infrastructure signoz-store
rezics-release rezics-release
rezics-release rezics-release-api-deploy
rezics-release rezics-release-build
rezics-release rezics-release-database
rezics-release rezics-release-maintenance
rezics-release rezics-release-projection
rezics-release rezics-release-worker-deploy
default webhook
JOBS

policy_dir="$(mktemp -d)"
trap 'rm -rf "$policy_dir"' EXIT
cat >"$policy_dir/outline.hcl" <<'POLICY'
namespace "default" {
  variables {
    path "nomad/jobs/outline" { capabilities = ["read"] }
  }
}
POLICY
for association in 'outline-app outline-app-runtime outline outline' 'outline-postgres outline-postgres-runtime postgres postgres'; do
  read -r job policy group task <<<"$association"
  nomad acl policy apply -namespace default -job "$job" -group "$group" -task "$task" \
    "$policy" "$policy_dir/outline.hcl" >/dev/null
done
for association in 'rezics-databasus rezics-databasus-runtime databasus databasus database/databasus-control' \
  'rezics-databasus-verification-agent rezics-databasus-verification-agent verification-agent verification-agent database/databasus-verification-agent'; do
  read -r job policy group task path <<<"$association"
  printf 'namespace "rezics-infrastructure" { variables { path "%s" { capabilities = ["read"] } } }\n' "$path" >"$policy_dir/backup.hcl"
  nomad acl policy apply -namespace rezics-infrastructure -job "$job" -group "$group" -task "$task" \
    "$policy" "$policy_dir/backup.hcl" >/dev/null
done
cat >"$policy_dir/control.hcl" <<'POLICY'
namespace "rezics-infrastructure" {
  variables {
    path "database/databasus-control" { capabilities = ["read"] }
    path "database/databasus-control-backup" { capabilities = ["read"] }
  }
}
POLICY
nomad acl policy apply -namespace rezics-infrastructure -job rezics-databasus-control-backup \
  -group backup -task backup rezics-databasus-control-backup "$policy_dir/control.hcl" >/dev/null
nomad job run -detach /etc/fleet-services/outline-postgres.nomad.hcl >/dev/null
nomad job run -detach /etc/fleet-services/outline-app.nomad.hcl >/dev/null
nomad job run -detach /etc/fleet-services/databasus.nomad.hcl >/dev/null
nomad job run -detach /etc/fleet-services/databasus-verification-agent.nomad.hcl >/dev/null
printf 'Outline and PostgreSQL backup services reconciled\n'
