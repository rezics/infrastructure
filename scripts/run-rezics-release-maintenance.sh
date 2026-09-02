#!/usr/bin/env bash

set -euo pipefail

readonly release="${NOMAD_META_release:?}"
readonly commit="${NOMAD_META_commit:?}"

if [[ ! "${release}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	[[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
	printf '%s\n' "Maintenance cutover metadata is invalid" >&2
	exit 64
fi

fallback_response="$({
	curl --fail --silent --show-error \
		--noproxy '*' \
		--connect-timeout 5 \
		--max-time 10 \
		--header 'Host: rezics-maintenance.internal' \
		http://127.0.0.1:8080/_health
})"
readonly fallback_response
jq -e '.status == "maintenance-ready"' <<<"${fallback_response}" >/dev/null

stop_job() {
	local job_id="$1"
	local job_status
	local live_allocations
	local stop_deadline

	job_status="$({
		rezics-nomad job inspect -namespace=rezics -json "${job_id}" |
			jq -er '.Status'
	})"

	if [[ "${job_status}" != dead ]]; then
		timeout --signal=TERM --kill-after=5s 240 \
			rezics-nomad job stop -namespace=rezics -no-color -yes "${job_id}"
	fi

	job_status="$({
		rezics-nomad job inspect -namespace=rezics -json "${job_id}" |
			jq -er '.Status'
	})"
	if [[ "${job_status}" != dead ]]; then
		printf 'Production job %s did not stop; status is %s\n' \
			"${job_id}" "${job_status}" >&2
		exit 1
	fi

	stop_deadline=$((SECONDS + 240))
	while true; do
		live_allocations="$({
			rezics-nomad job allocs -namespace=rezics -all -json "${job_id}" |
				jq '[.[] | select(.ClientStatus == "pending" or .ClientStatus == "running")] | length'
		})"
		if [[ "${live_allocations}" == 0 ]]; then
			break
		fi
		if ((SECONDS >= stop_deadline)); then
			printf 'Production job %s still has %s live allocations\n' \
				"${job_id}" "${live_allocations}" >&2
			exit 1
		fi
		sleep 1
	done

	printf 'Production job %s is stopped\n' "${job_id}"
}

# Stop writers first, then remove API traffic before applying a contract migration.
stop_job rezics-worker
stop_job rezics-api

printf 'Maintenance cutover for %s at %s is active\n' "${release}" "${commit}"
