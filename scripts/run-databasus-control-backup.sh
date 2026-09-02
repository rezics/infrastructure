#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly management_token_file="${REZICS_NOMAD_MANAGEMENT_TOKEN_FILE:?}"
readonly backup_job_file="${REZICS_DATABASUS_CONTROL_BACKUP_JOB_FILE:?}"
readonly namespace=rezics-infrastructure
readonly service_job=rezics-databasus
readonly service_group=databasus
readonly backup_job=rezics-databasus-control-backup

for required_file in "${management_token_file}" "${backup_job_file}"; do
	if [[ ! -r "${required_file}" ]]; then
		printf 'Required control-backup input is missing: %s\n' "${required_file}" >&2
		exit 1
	fi
done

export NOMAD_ADDR=https://127.0.0.1:4646
export NOMAD_TLS_SERVER_NAME=server.global.nomad
export NOMAD_NAMESPACE="${namespace}"
NOMAD_TOKEN="$(<"${management_token_file}")"
export NOMAD_TOKEN

service_quiesced=false

wait_for_service_health() {
	local healthy=false
	for _attempt in $(seq 1 120); do
		if nomad job allocs -namespace="${namespace}" -json "${service_job}" |
			jq -e 'any(.[]; .ClientStatus == "running" and .DeploymentStatus.Healthy == true)' \
				>/dev/null; then
			healthy=true
			break
		fi
		sleep 5
	done
	if [[ "${healthy}" != true ]]; then
		printf 'Databasus did not become healthy after the control backup\n' >&2
		return 1
	fi
}

resume_service() {
	nomad job scale -namespace="${namespace}" -detach \
		"${service_job}" "${service_group}" 1 >/dev/null
	wait_for_service_health
}

cleanup() {
	local exit_code=$?
	trap - EXIT INT TERM
	if [[ "${service_quiesced}" == true ]]; then
		if ! resume_service; then
			exit 70
		fi
	fi
	exit "${exit_code}"
}
trap cleanup EXIT INT TERM

desired_count="$(
	nomad job inspect -namespace="${namespace}" -json "${service_job}" |
		jq -er '.TaskGroups[] | select(.Name == "databasus") | .Count'
)"
if [[ "${desired_count}" != 1 ]]; then
	printf 'Refusing control backup with unexpected Databasus count: %s\n' \
		"${desired_count}" >&2
	exit 1
fi

if nomad job inspect -namespace="${namespace}" -json "${backup_job}" >/dev/null 2>&1; then
	nomad job stop -namespace="${namespace}" -detach -purge "${backup_job}" >/dev/null
fi

nomad job scale -namespace="${namespace}" -detach \
	"${service_job}" "${service_group}" 0 >/dev/null
service_quiesced=true

stopped=false
for _attempt in $(seq 1 120); do
	if ! nomad job allocs -namespace="${namespace}" -json "${service_job}" |
		jq -e 'any(.[]; .ClientStatus == "running" or .ClientStatus == "pending")' \
			>/dev/null; then
		stopped=true
		break
	fi
	sleep 5
done
if [[ "${stopped}" != true ]]; then
	printf 'Databasus did not stop cleanly before the control backup\n' >&2
	exit 1
fi

nomad job run -namespace="${namespace}" -no-color -detach "${backup_job_file}" >/dev/null

backup_status=''
for _attempt in $(seq 1 180); do
	backup_status="$(
		nomad job allocs -namespace="${namespace}" -json "${backup_job}" |
			jq -r 'sort_by(.CreateIndex) | last | .ClientStatus // empty'
	)"
	case "${backup_status}" in
	complete) break ;;
	failed | lost) break ;;
	esac
	sleep 5
done

if [[ "${backup_status}" != complete ]]; then
	printf 'Databasus control backup finished with status: %s\n' \
		"${backup_status:-unknown}" >&2
	exit 1
fi

printf '%s\n' 'Databasus control backup and restore-read verification completed'
