#!/usr/bin/env bash
set -euo pipefail

test -f flake.nix
test -f modules/rezics-platform.nix
test -f packages/release-gateway.nix
test -f services/release-gateway/main.go
test ! -e hosts
test ! -e secrets
test ! -e .sops.yaml
rg -q '^[[:space:]]+edge[[:space:]]*=' flake.nix
rg -q '^[[:space:]]+data[[:space:]]*=' flake.nix
rg -q 'options\.services\.rezicsPlatform[[:space:]]*=' modules/rezics-platform.nix
rg -q '^[[:space:]]+credentialFiles[[:space:]]*=' modules/rezics-platform.nix
rg -q '^[[:space:]]+credentialProvisioningUnits[[:space:]]*=' modules/rezics-platform.nix

if rg -n --glob '*.hcl' \
  '127\.0\.0\.1:5000|localhost:5000|image\s*=\s*"[^"]+:latest"|\b(POSTGRES_PASSWORD|SMTP_PASSWORD|GITHUB_CLIENT_SECRET|PRIVATE_KEY)\s*=' \
  jobs | grep -v -E '\{\{'; then
  echo 'floating registry, floating image, or literal credential found' >&2
  exit 1
fi

if rg -n --glob '!scripts/check-public-policy.sh' \
	--glob '*.nix' --glob '*.hcl' --glob '*.yaml' --glob '*.yml' --glob '*.sh' --glob '*.go' -- \
	'ENC\[AES256_GCM|age1[0-9a-z]{20,}|ssh-ed25519[[:space:]]+[A-Za-z0-9+/]{20,}|wireguardPeerPublicKey[[:space:]]*=[[:space:]]*"|-----BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY-----|ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+' \
	.; then
	echo 'encrypted secret, machine identity, private key, or GitHub token found' >&2
  exit 1
fi

test "$(rg -l 'memory_max' jobs | wc -l)" -ge 1

if rg -n '^[[:space:]]+read_only[[:space:]]*=' \
  jobs/edge/observability/signoz-agent.nomad.hcl; then
  echo 'Docker bind mounts must use the Nomad driver readonly field' >&2
  exit 1
fi

if rg -n '^[[:space:]]+pid_mode[[:space:]]*=' \
  jobs/edge/observability/signoz-agent.nomad.hcl; then
  echo 'The metrics-only SigNoz agents must not share the host PID namespace' >&2
  exit 1
fi

if rg -n '^[[:space:]]+command[[:space:]]*=[[:space:]]*"/otelcol-contrib"' \
  jobs/edge/observability/signoz-agent.nomad.hcl; then
  echo 'The OpenTelemetry image already defines /otelcol-contrib as its entrypoint' >&2
  exit 1
fi

test "$(rg -c '^[[:space:]]+user[[:space:]]*=[[:space:]]*"0"' \
  jobs/edge/observability/signoz-agent.nomad.hcl)" -eq 2

test "$(rg -c '^[[:space:]]+api_version:[[:space:]]*"1\.40"' \
  jobs/edge/observability/signoz-agent.nomad.hcl)" -eq 2

test "$(rg -c '^[[:space:]]+scrape_interval:[[:space:]]*60s' \
  jobs/edge/observability/signoz-agent.nomad.hcl)" -eq 2
test "$(rg -c '^[[:space:]]+key:[[:space:]]*host\.id' \
  jobs/edge/observability/signoz-agent.nomad.hcl)" -eq 5
test "$(rg -c '^[[:space:]]+collection_interval:[[:space:]]*60s' \
  jobs/edge/observability/signoz-agent.nomad.hcl)" -eq 5
rg -q '^[[:space:]]+postgresql:' jobs/edge/observability/signoz-agent.nomad.hcl
rg -q 'nomad/jobs/signoz-agent' jobs/edge/observability/signoz-agent.nomad.hcl

for service_job in \
  jobs/edge/release/rezics-api.nomad.hcl \
  jobs/edge/release/rezics-worker.nomad.hcl; do
  rg -q 'OTEL_EXPORTER_OTLP_ENDPOINT[[:space:]]*=[[:space:]]*"http://10\.64\.0\.1:4318"' \
    "${service_job}"
  rg -q 'OTEL_TRACES_SAMPLER[[:space:]]*=[[:space:]]*"parentbased_always_on"' \
    "${service_job}"
  rg -q 'OTEL_METRIC_EXPORT_INTERVAL[[:space:]]*=[[:space:]]*"60000"' \
    "${service_job}"
done

rg -q '^[[:space:]]+tail_sampling:' \
  jobs/edge/observability/signoz-core.nomad.hcl
rg -q 'sampling_percentage: 1' \
  jobs/edge/observability/signoz-core.nomad.hcl
rg -q 'status_codes:' \
  jobs/edge/observability/signoz-core.nomad.hcl

for root_variable in \
  SIGNOZ_USER_ROOT_EMAIL \
  SIGNOZ_USER_ROOT_PASSWORD \
  SIGNOZ_USER_ROOT_ORG_NAME \
  SIGNOZ_USER_ROOT_ORG_ID; do
  rg -q "${root_variable}" jobs/edge/observability/signoz-core.nomad.hcl
  rg -q "${root_variable}" scripts/reconcile-rezics-platform.sh
done

rg -q 'port[[:space:]]*=[[:space:]]*"clickhouse-http"' \
  jobs/data/observability/signoz-store.nomad.hcl

traefik_policy="$(sed -n '/policy_directory}\/traefik\.hcl/,/^EOF$/p' scripts/bootstrap-nomad-acl.sh)"
traefik_namespaces="$(sed -n '/namespaces = \[/,/];/p' modules/rezics-platform.nix)"
for namespace in default rezics rezics-infrastructure; do
  grep -Fq "namespace \"${namespace}\"" <<<"${traefik_policy}"
  grep -Fq "\"${namespace}\"" <<<"${traefik_namespaces}"
done

control_backup_job=jobs/data/backup/databasus-control-backup.nomad.hcl
rg -q 'restic/restic@sha256:[0-9a-f]{64}' "${control_backup_job}"
rg -q 'read_only[[:space:]]*=[[:space:]]*true' "${control_backup_job}"
rg -q 'attempts[[:space:]]*=[[:space:]]*0' "${control_backup_job}"
rg -q 'unlimited[[:space:]]*=[[:space:]]*false' "${control_backup_job}"
rg -q -- '--read-data' "${control_backup_job}"
rg -q -- '--dry-run' "${control_backup_job}"
rg -q 'keep-daily 7' "${control_backup_job}"
rg -q 'keep-weekly 4' "${control_backup_job}"

postgres_job=jobs/data/database/rezics-postgres.nomad.hcl
pgbouncer_job=jobs/data/database/rezics-pgbouncer.nomad.hcl
databasus_job=jobs/data/backup/databasus.nomad.hcl
databasus_verification_agent_job=jobs/data/backup/databasus-verification-agent.nomad.hcl
database_reconcile=scripts/reconcile-rezics-database.sh

rg -q 'rezics-postgres@sha256:[0-9a-f]{64}' "${postgres_job}"
for setting in \
	'max_connections=120' \
	'reserved_connections=10' \
	'shared_buffers=12GB' \
	'autovacuum_max_workers=6' \
	'autovacuum_vacuum_scale_factor=0.01' \
	'io_method=worker' \
	'pgroonga.enable_wal_resource_manager=on' \
	'pgroonga.enable_wal=off' \
	'pgroonga.enable_crash_safe=on'; do
	rg -Fq "${setting}" "${postgres_job}"
done

rg -q 'edoburu/pgbouncer:v1\.25\.2-p0@sha256:[0-9a-f]{64}' "${pgbouncer_job}"
rg -Fq 'nomad/jobs/rezics-pgbouncer/pgbouncer/pgbouncer' "${pgbouncer_job}"
rg -Fq 'rezics = host=10.64.0.2 port=5432' "${pgbouncer_job}"
rg -Fq 'name     = "pgbouncer-tcp"' "${pgbouncer_job}"
for pool_contract in \
	'pool_mode=transaction pool_size=40' \
	'max_db_connections=48' \
	'pool_mode=session pool_size=4' \
	'max_client_conn = 512' \
	'max_prepared_statements = 256' \
	'auth_type = scram-sha-256'; do
	rg -Fq "${pool_contract}" "${pgbouncer_job}"
done

rg -q 'databasus/databasus:v3\.51\.0@sha256:[0-9a-f]{64}' "${databasus_job}"
rg -Fq 'database/databasus-control' "${databasus_job}"
rg -Fq 'secrets/secret.key:/databasus-data/secret.key:ro' "${databasus_job}"
rg -Fq 'check_restart {' "${databasus_job}"
rg -Fq 'grace = "2m"' "${databasus_job}"
rg -q 'alpine:3\.23\.3@sha256:[0-9a-f]{64}' "${databasus_verification_agent_job}"
rg -Fq '"verificationPgImageRepo": "10.64.0.1:5000/rezics-postgres-verification"' \
	"${databasus_verification_agent_job}"
rg -Fq '/var/run/docker.sock:/var/run/docker.sock' "${databasus_verification_agent_job}"

for job_file_variable in \
	REZICS_POSTGRES_JOB_FILE \
	REZICS_PGBOUNCER_JOB_FILE \
	REZICS_DATABASUS_JOB_FILE \
	REZICS_DATABASUS_VERIFICATION_AGENT_JOB_FILE; do
	rg -Fq "${job_file_variable}" "${database_reconcile}" modules/rezics-platform.nix
done
rg -Fq 'nomad job run -no-color "${postgres_job_file}"' "${database_reconcile}"
rg -Fq 'nomad var get -out=json "${postgres_variable_path}"' "${database_reconcile}"
rg -Fq 'nomad var put -in=json -out=none -force -' "${database_reconcile}"
rg -Fq 'nomad job run -no-color "${pgbouncer_job_file}"' "${database_reconcile}"
rg -Fq 'PGCONNECT_TIMEOUT=2 PGPASSWORD="${pgbouncer_password}"' "${database_reconcile}"
rg -Fq -- "--command='SELECT 1'" "${database_reconcile}"
database_reconcile_definition="$(
	sed -n '/^  reconcileRezicsDatabase =/,/^  };/p' modules/rezics-platform.nix
)"
platform_reconcile_definition="$(
	sed -n '/^  reconcileRezicsPlatform =/,/^  };/p' modules/rezics-platform.nix
)"
grep -Fq 'pkgs.postgresql_18' <<<"${database_reconcile_definition}"
if grep -Fq 'pkgs.postgresql_18' <<<"${platform_reconcile_definition}"; then
	printf '%s\n' 'PostgreSQL client belongs only to the database reconciler' >&2
	exit 1
fi
rg -Fq 'nomad job run -no-color "${databasus_job_file}"' "${database_reconcile}"
rg -Fq 'nomad job run -no-color "${databasus_verification_agent_job_file}"' \
	"${database_reconcile}"
rg -Fq 'restartTriggers = [' modules/rezics-platform.nix
for database_job_path in \
	'../jobs/data/database/rezics-postgres.nomad.hcl' \
	'../jobs/data/database/rezics-pgbouncer.nomad.hcl' \
	'../jobs/data/backup/databasus.nomad.hcl' \
	'../jobs/data/backup/databasus-verification-agent.nomad.hcl'; do
	rg -Fq "${database_job_path}" modules/rezics-platform.nix
done
