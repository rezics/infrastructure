#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly management_token_file="${REZICS_NOMAD_MANAGEMENT_TOKEN_FILE:?}"
readonly postgres_job_file="${REZICS_POSTGRES_JOB_FILE:?}"
readonly pgbouncer_job_file="${REZICS_PGBOUNCER_JOB_FILE:?}"
readonly databasus_job_file="${REZICS_DATABASUS_JOB_FILE:?}"
readonly databasus_verification_agent_job_file="${REZICS_DATABASUS_VERIFICATION_AGENT_JOB_FILE:?}"
readonly postgres_variable_path="nomad/jobs/rezics-postgres/postgres/postgres"
readonly pgbouncer_variable_path="nomad/jobs/rezics-pgbouncer/pgbouncer/pgbouncer"

for required_file in \
	"${management_token_file}" \
	"${postgres_job_file}" \
	"${pgbouncer_job_file}" \
	"${databasus_job_file}" \
	"${databasus_verification_agent_job_file}"; do
	if [[ ! -r "${required_file}" ]]; then
		printf 'Required database input is missing: %s\n' "${required_file}" >&2
		exit 1
	fi
done

export NOMAD_ADDR="https://127.0.0.1:4646"
export NOMAD_TLS_SERVER_NAME="server.global.nomad"
export NOMAD_NAMESPACE="rezics-infrastructure"
management_token="$(<"${management_token_file}")"
export NOMAD_TOKEN="${management_token}"

for job_file in \
	"${postgres_job_file}" \
	"${pgbouncer_job_file}" \
	"${databasus_job_file}" \
	"${databasus_verification_agent_job_file}"; do
	nomad job validate "${job_file}"
done

nomad job run -no-color "${postgres_job_file}"

# A task workload identity can only read Nomad variables under its own
# job/group/task path. Mirror the two application credentials without placing
# their values in Nix, process arguments, or logs.
nomad var get -out=json "${postgres_variable_path}" |
	jq -e --arg destination "${pgbouncer_variable_path}" '
    (.Items.REZICS_DATABASE_USERNAME | select(type == "string" and length > 0)) as $username |
    (.Items.REZICS_DATABASE_PASSWORD | select(type == "string" and length > 0)) as $password |
    {
      Namespace: .Namespace,
      Path: $destination,
      Items: {
        REZICS_DATABASE_USERNAME: $username,
        REZICS_DATABASE_PASSWORD: $password
      }
    }
  ' |
	nomad var put -in=json -out=none -force -

nomad job run -no-color "${pgbouncer_job_file}"

pgbouncer_username="$({
	nomad var get -out=json "${postgres_variable_path}" |
		jq -er '.Items.REZICS_DATABASE_USERNAME | select(type == "string" and length > 0)'
})"
pgbouncer_password="$({
	nomad var get -out=json "${postgres_variable_path}" |
		jq -er '.Items.REZICS_DATABASE_PASSWORD | select(type == "string" and length > 0)'
})"
pgbouncer_ready=false
for _ in $(seq 1 30); do
	if PGCONNECT_TIMEOUT=2 PGPASSWORD="${pgbouncer_password}" \
		psql \
			--host=10.64.0.2 \
			--port=6432 \
			--username="${pgbouncer_username}" \
			--dbname=rezics \
			--no-password \
			--tuples-only \
			--no-align \
			--command='SELECT 1' >/dev/null 2>&1; then
		pgbouncer_ready=true
		break
	fi
	sleep 2
done
unset pgbouncer_password
if [[ "${pgbouncer_ready}" != "true" ]]; then
	printf '%s\n' "PgBouncer did not pass its SQL readiness query" >&2
	exit 1
fi

nomad job run -no-color "${databasus_job_file}"
nomad job run -no-color "${databasus_verification_agent_job_file}"
printf '%s\n' "PostgreSQL, PgBouncer, Databasus, and its verification agent jobs reconciled"
