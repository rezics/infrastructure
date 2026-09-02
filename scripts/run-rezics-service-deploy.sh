#!/usr/bin/env bash

set -euo pipefail
umask 077

if (($# != 1)) || [[ "$1" != "api" && "$1" != "worker" ]]; then
	printf '%s\n' "Usage: run-rezics-service-deploy.sh <api|worker>" >&2
	exit 64
fi

readonly component="$1"
readonly release="${NOMAD_META_release:?}"
readonly commit="${NOMAD_META_commit:?}"
readonly image="${NOMAD_META_image:?}"
readonly job_id="rezics-${component}"
readonly jobspec="/etc/rezics-release/${component}.nomad.hcl"
readonly image_variable="${component}_image"
readonly timeout_seconds=2400
readonly registry_address="${REZICS_REGISTRY_ADDRESS:-10.64.0.1:5000}"

if [[ ! "${release}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	[[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]] ||
	[[ "${registry_address}" != 10.64.0.1:5000 ]] ||
	[[ "${image}" != "${registry_address}/rezics-${component}@sha256:"* ]] ||
	[[ ! "${image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]] ||
	[[ ! -r "${jobspec}" ]]; then
	printf '%s\n' "Service deployment metadata or jobspec is invalid" >&2
	exit 64
fi

plan_output="$(mktemp)"
run_output="$(mktemp)"
readonly plan_output run_output
cleanup() {
	rm -f "${plan_output}" "${run_output}"
}
trap cleanup EXIT

timeline() {
	printf 'REZICS_TIMELINE %s %s\n' \
		"$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

dump_service_failure() {
	local evaluation_id="$1"
	local job_status latest_deployment_id allocations
	local latest_version allocation_id log_type
	printf 'REZICS_FAILURE service=%s evaluation=%s\n' "${job_id}" "${evaluation_id:-unknown}" >&2

	if [[ "${evaluation_id}" =~ ^[0-9a-f-]{8,64}$ ]]; then
		timeout --signal=TERM --kill-after=5s 30 \
			rezics-nomad eval status -namespace=rezics -no-color \
			"${evaluation_id}" 2>&1 | head -c 65536 >&2 || true
	fi

	job_status="$(rezics-nomad job status -namespace=rezics -json "${job_id}" 2>/dev/null || printf '{}')"
	latest_deployment_id="$(jq -r '
		if type == "array" then .[0] else . end |
		.LatestDeployment.ID // empty
	' <<<"${job_status}")"
	latest_version="$(jq -r '
		if type == "array" then .[0] else . end |
		.LatestDeployment.JobVersion // empty
	' <<<"${job_status}")"
	if [[ "${latest_deployment_id}" =~ ^[0-9a-f-]{8,64}$ ]]; then
		printf 'REZICS_FAILURE deployment=%s\n' "${latest_deployment_id}" >&2
		timeout --signal=TERM --kill-after=5s 30 \
			rezics-nomad deployment status -namespace=rezics -no-color -verbose \
			"${latest_deployment_id}" 2>&1 | head -c 131072 >&2 || true
	fi

	allocations="$(rezics-nomad job allocs -namespace=rezics -all -json "${job_id}" 2>/dev/null || printf '[]')"
	if [[ "${latest_version}" =~ ^[0-9]+$ ]]; then
		while IFS= read -r allocation_id; do
			[[ -n "${allocation_id}" ]] || continue
			printf 'REZICS_FAILURE allocation=%s\n' "${allocation_id}" >&2
			timeout --signal=TERM --kill-after=5s 30 \
				rezics-nomad alloc status -namespace=rezics -verbose \
				"${allocation_id}" 2>&1 | head -c 65536 >&2 || true
			for log_type in stdout stderr; do
				log_flag="-${log_type}"
				printf 'REZICS_FAILURE allocation=%s log=%s\n' \
					"${allocation_id}" "${log_type}" >&2
				timeout --signal=TERM --kill-after=5s 30 \
					rezics-nomad alloc logs -namespace=rezics "${log_flag}" \
					-tail -n 200 "${allocation_id}" "${component}" 2>&1 |
					head -c 65536 >&2 || true
			done
		done < <(
			jq -r --argjson version "${latest_version}" \
				'[.[] | select(.JobVersion == $version and (.ClientStatus != "complete" or .DesiredStatus == "stop")) | .ID] | .[0:8][]' \
				<<<"${allocations}"
		)
	else
		while IFS= read -r allocation_id; do
			[[ -n "${allocation_id}" ]] || continue
			printf 'REZICS_FAILURE allocation=%s\n' "${allocation_id}" >&2
			timeout --signal=TERM --kill-after=5s 30 \
				rezics-nomad alloc status -namespace=rezics -verbose \
				"${allocation_id}" 2>&1 | head -c 65536 >&2 || true
		done < <(
			jq -r '[.[] | select(.ClientStatus == "failed" or .ClientStatus == "lost") | .ID] | .[0:8][]' \
				<<<"${allocations}"
		)
	fi
}

timeline "phase=${component} plan status=starting"
set +e
rezics-nomad job plan -namespace=rezics -no-color \
	-var "release=${release}" -var "${image_variable}=${image}" \
	"${jobspec}" 2>&1 | tee "${plan_output}"
plan_status=${PIPESTATUS[0]}
set -e
if ((plan_status != 0 && plan_status != 1)); then
	printf 'Nomad plan failed with exit status %s\n' "${plan_status}" >&2
	timeline "phase=${component} plan status=failed"
	exit "${plan_status}"
fi

modify_index="$(sed -n 's/^Job Modify Index: //p' "${plan_output}" | tail -n 1)"
if [[ ! "${modify_index}" =~ ^[0-9]+$ ]]; then
	printf '%s\n' "Nomad plan did not return a valid Job Modify Index" >&2
	timeline "phase=${component} plan status=failed reason=missing-modify-index"
	exit 1
fi

timeline "phase=${component} deployment status=starting"
set +e
timeout --signal=TERM --kill-after=10s "${timeout_seconds}" \
	rezics-nomad job run -namespace=rezics -no-color -verbose \
		-preserve-counts -preserve-resources \
		-check-index="${modify_index}" \
		-var "release=${release}" -var "${image_variable}=${image}" \
		"${jobspec}" 2>&1 | tee "${run_output}"
run_status=${PIPESTATUS[0]}
set -e

evaluation_id="$(sed -n \
	-e 's/^.*Monitoring evaluation \"\\([0-9a-f-]*\\)\".*$/\\1/p' \
	-e 's/^Evaluation ID:[[:space:]]*//p' \
	"${run_output}" | tail -n 1)"
if ((run_status != 0)); then
	printf 'Nomad deployment for %s ended with exit status %s\n' "${job_id}" "${run_status}" >&2
	dump_service_failure "${evaluation_id}"
	timeline "phase=${component} deployment status=failed evaluation=${evaluation_id:-unknown}"
	if ((run_status == 2)); then
		exit 2
	fi
	exit 1
fi

timeline "phase=${component} deployment status=complete evaluation=${evaluation_id:-unknown}"
printf 'Nomad deployment for %s completed\n' "${job_id}"
