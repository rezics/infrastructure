#!/usr/bin/env bash

set -euo pipefail
umask 077

if (($# != 4)); then
	printf '%s\n' \
		"Usage: run-rezics-release.sh <controller-repository> <workload-repository> <release> <commit>" >&2
	exit 64
fi

readonly repository_directory="$1"
readonly workload_repository="$2"
readonly release="$3"
readonly commit="$4"
readonly state_directory="${REZICS_RELEASE_STATE_DIRECTORY:-/var/lib/rezics-release}"
readonly current_release_file="${state_directory}/current-release.json"
readonly component_state_file="${state_directory}/component-state.json"
readonly plans_directory="${state_directory}/plans"
readonly registry_address="${REZICS_REGISTRY_ADDRESS:-10.64.0.1:5000}"

if [[ "${registry_address}" != 10.64.0.1:5000 ]]; then
	printf '%s\n' "Refusing a registry outside the private WireGuard endpoint" >&2
	exit 64
fi

if [[ ! "${release}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	[[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]] ||
	[[ ! "${NOMAD_ALLOC_ID:-}" =~ ^[0-9a-f-]{36}$ ]]; then
	printf '%s\n' "Release identity is malformed" >&2
	exit 64
fi

install -d -m 0700 "${state_directory}" "${plans_directory}"
exec 9>"${state_directory}/release.lock"
flock 9

timeline() {
	printf 'REZICS_TIMELINE %s %s\n' \
		"$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

timeline "phase=release release=${release} commit=${commit} status=started"

dump_batch_failure() {
	local dispatched_job_id="$1"
	local allocations allocation_id
	printf 'REZICS_FAILURE job=%s\n' "${dispatched_job_id}" >&2
	timeout --signal=TERM --kill-after=5s 30 \
		nomad job status -namespace=rezics-release -evals -all-allocs -no-color \
		"${dispatched_job_id}" 2>&1 | head -c 131072 >&2 || true
	allocations="$(timeout --signal=TERM --kill-after=5s 30 \
		nomad job allocs -namespace=rezics-release -all -json \
		"${dispatched_job_id}" 2>/dev/null || printf '[]')"
	while IFS= read -r allocation_id; do
		[[ -n "${allocation_id}" ]] || continue
		printf 'REZICS_FAILURE allocation=%s\n' "${allocation_id}" >&2
		timeout --signal=TERM --kill-after=5s 30 \
			nomad alloc status -namespace=rezics-release -verbose \
			"${allocation_id}" 2>&1 | head -c 65536 >&2 || true
		for log_type in stdout stderr; do
			log_flag="-${log_type}"
			printf 'REZICS_FAILURE allocation=%s log=%s\n' \
				"${allocation_id}" "${log_type}" >&2
			timeout --signal=TERM --kill-after=5s 30 \
				nomad alloc logs -namespace=rezics-release "${log_flag}" \
				-tail -n 200 "${allocation_id}" 2>&1 |
				head -c 65536 >&2 || true
		done
	done < <(
		jq -r '[.[] | select(.ClientStatus == "failed" or .ClientStatus == "lost") | .ID] | .[0:8][]' \
			<<<"${allocations}"
	)
}

if [[ -r "${current_release_file}" ]]; then
	current_release="$(jq -er '.release' "${current_release_file}")"
	current_commit="$(jq -er '.commit' "${current_release_file}")"
	if [[ "${current_release}" == "${release}" && "${current_commit}" != "${commit}" ]]; then
		if [[ "${release}" != v1.0.0 ]]; then
			printf 'Refusing to move immutable release %s from %s to %s\n' \
				"${release}" "${current_commit}" "${commit}" >&2
			exit 1
		fi
		printf 'Reinstalling the one-time v1.0.0 baseline from %s to %s\n' \
			"${current_commit}" "${commit}"
	fi
	if [[ "${current_release}" != "${release}" ]] &&
		[[ "$(printf '%s\n%s\n' "${current_release}" "${release}" | sort -V | tail -n 1)" != "${release}" ]]; then
		printf 'Refusing release downgrade from %s to %s\n' \
			"${current_release}" "${release}" >&2
		exit 1
	fi
fi

cd "${repository_directory}"
observed_commit="$(git rev-parse 'HEAD^{commit}')"
observed_tag_commit="$(git rev-parse "refs/tags/${release}^{commit}")"
if [[ "${observed_commit}" != "${commit}" || "${observed_tag_commit}" != "${commit}" ]]; then
	printf '%s\n' "Checked-out commit and release tag do not match the dispatch identity" >&2
	exit 1
fi
git merge-base --is-ancestor "${commit}" refs/remotes/origin/main

if [[ ! -s "${component_state_file}" ]]; then
	printf '%s\n' '{"schemaVersion":2,"components":{}}' >"${component_state_file}"
	chmod 0600 "${component_state_file}"
fi
jq -e '.schemaVersion == 2 and (.components | type == "object")' \
	"${component_state_file}" >/dev/null

# Web releases are owned by GitHub. Remove the legacy entry left by releases
# created before the server and Web release graphs were split.
normalized_component_state="$(mktemp "${component_state_file}.XXXXXX")"
jq 'del(.components.web)' "${component_state_file}" >"${normalized_component_state}"
chmod 0600 "${normalized_component_state}"
mv "${normalized_component_state}" "${component_state_file}"

plan_file="${plans_directory}/${commit}.json"
temporary_plan="$(mktemp "${plan_file}.XXXXXX")"
"${repository_directory}/deploy/scripts/plan-release-components.sh" \
	"${component_state_file}" "${release}" >"${temporary_plan}"
chmod 0600 "${temporary_plan}"
mv "${temporary_plan}" "${plan_file}"

component_hash() {
	local component="$1"
	jq -er --arg component "${component}" \
		'.components[] | select(.name == $component) | .inputHash' "${plan_file}"
}

component_changed() {
	local component="$1"
	jq -e --arg component "${component}" \
		'.components[] | select(.name == $component) | .changed' \
		"${plan_file}" >/dev/null
}

record_component() {
	local component="$1"
	local input_hash="$2"
	local artifact="$3"
	local temporary_state
	temporary_state="$(mktemp "${component_state_file}.XXXXXX")"
	jq \
		--arg component "${component}" \
		--arg input_hash "${input_hash}" \
		--arg release "${release}" \
		--arg commit "${commit}" \
		--arg completed_at "$(date --utc --iso-8601=seconds)" \
		--argjson artifact "${artifact}" \
		'.schemaVersion = 2 |
		 .components[$component] = {
		   inputHash: $input_hash,
		   release: $release,
		   commit: $commit,
		   artifact: $artifact,
		   completedAt: $completed_at
		 }' "${component_state_file}" >"${temporary_state}"
	chmod 0600 "${temporary_state}"
	mv "${temporary_state}" "${component_state_file}"
}

dispatch_release_job() {
	local job="$1"
	local idempotency_suffix="$2"
	shift 2
	local idempotency_token
	local dispatch_output
	local dispatched_job_id
	local evaluation_id
	local timeout_seconds
	timeline "phase=dispatch job=${job} status=starting"
	idempotency_token="$(printf '%s' "${NOMAD_JOB_ID}:${idempotency_suffix}" | sha256sum | cut -d' ' -f1)"
	case "${job}" in
		rezics-release-build) timeout_seconds=10800 ;;
		rezics-release-maintenance) timeout_seconds=600 ;;
		rezics-release-api-deploy | rezics-release-worker-deploy) timeout_seconds=2700 ;;
		*) timeout_seconds=1800 ;;
	esac
	dispatch_output="$(
		nomad job dispatch -namespace=rezics-release -no-color -detach \
			-idempotency-token="${idempotency_token}" "$@" "${job}"
	)"
	printf '%s\n' "${dispatch_output}"
	dispatched_job_id="$(
		sed -n 's/^Dispatched Job ID[[:space:]]*[:=][[:space:]]*//p' \
			<<<"${dispatch_output}"
	)"
	if [[ ! "${dispatched_job_id}" =~ ^${job}/dispatch-[0-9]+-[a-zA-Z0-9]+$ ]]; then
		printf 'Nomad returned an invalid dispatched job ID for %s: %s\n' \
			"${job}" "${dispatched_job_id}" >&2
		exit 1
	fi
	evaluation_id="$(sed -n 's/^Evaluation ID[[:space:]]*[:=][[:space:]]*//p' <<<"${dispatch_output}" | tail -n 1)"
	timeline "phase=dispatch job=${job} dispatched_job=${dispatched_job_id} eval=${evaluation_id:-unknown} status=monitoring"
	if ! NOMAD_BIN=nomad NOMAD_BATCH_TIMEOUT_SECONDS="${timeout_seconds}" \
		"${repository_directory}/deploy/scripts/wait-nomad-batch.sh" \
		--namespace rezics-release "${dispatched_job_id}"; then
		dump_batch_failure "${dispatched_job_id}"
		timeline "phase=dispatch job=${job} dispatched_job=${dispatched_job_id} status=failed"
		return 1
	fi
	timeline "phase=dispatch job=${job} dispatched_job=${dispatched_job_id} status=complete"
}

publish_image() {
	local component="$1"
	local expected_archive="${workload_repository}/.rezics-release-artifacts/${component}.docker.tar"
	local recorded_archive
	local image_tag="${registry_address}/rezics-${component}:${commit}"
	local digest
	local policy="${REZICS_SKOPEO_POLICY:?}"
	if [[ ! -r "${policy}" ]]; then
		printf 'Release image trust policy is not readable: %s\n' "${policy}" >&2
		exit 1
	fi
	recorded_archive="$(jq -er --arg component "${component}" \
		'.artifacts[$component].dockerArchive' "${build_result}")"
	if [[ "${recorded_archive}" != "${expected_archive}" || ! -s "${expected_archive}" ]]; then
		printf 'Builder returned an invalid Docker image archive for %s\n' "${component}" >&2
		exit 1
	fi
	skopeo --policy "${policy}" copy --dest-tls-verify=false \
		"docker-archive:${expected_archive}" "docker://${image_tag}" >&2
	digest="$(skopeo inspect --tls-verify=false --format '{{.Digest}}' \
		"docker://${image_tag}")"
	if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
		printf 'Registry returned an invalid digest for %s\n' "${component}" >&2
		exit 1
	fi
	printf '%s/rezics-%s@%s\n' "${registry_address}" "${component}" "${digest}"
}

database_needed=false
api_needed=false
worker_needed=false
projection_needed=false
maintenance_required="$({
	jq -er '.maintenanceRequired |
		if type == "boolean" then tostring else error("invalid maintenance flag") end' \
		"${plan_file}"
})"
component_changed database && database_needed=true
component_changed api && api_needed=true
component_changed worker && worker_needed=true
component_changed projection && projection_needed=true
if [[ "${database_needed}" == true ]]; then
	api_needed=true
	worker_needed=true
	projection_needed=true
fi

changed_components="$(jq -r '[.components[] | select(.changed == true) | .name] | join(",")' "${plan_file}")"
timeline "phase=plan release=${release} commit=${commit} maintenance=${maintenance_required} changed=${changed_components:-none}"

build_components=()
[[ "${database_needed}" == true ]] && build_components+=(database)
[[ "${api_needed}" == true ]] && build_components+=(api)
[[ "${worker_needed}" == true ]] && build_components+=(worker)

build_result="${workload_repository}/.rezics-release-build.json"
rm -f "${build_result}"
if ((${#build_components[@]} > 0)); then
	components_csv="$(IFS=,; printf '%s' "${build_components[*]}")"
	timeline "phase=build components=${components_csv} status=starting"
	dispatch_release_job rezics-release-build "build:${components_csv}" \
		-meta "workspace_id=${NOMAD_ALLOC_ID}" \
		-meta "release=${release}" \
		-meta "commit=${commit}" \
		-meta "components=${components_csv}"
	jq -e --arg release "${release}" --arg commit "${commit}" \
		'.schemaVersion == 1 and .release == $release and .commit == $commit and
		 (.artifacts | type == "object")' "${build_result}" >/dev/null
fi

database_image=''
api_image=''
worker_image=''
[[ "${database_needed}" == true ]] && database_image="$(publish_image database)"
[[ "${api_needed}" == true ]] && api_image="$(publish_image api)"
[[ "${worker_needed}" == true ]] && worker_image="$(publish_image worker)"

if [[ "${database_needed}" == true && "${maintenance_required}" == true ]]; then
	timeline "phase=maintenance status=starting"
	dispatch_release_job rezics-release-maintenance \
		"maintenance:$(component_hash database)" \
		-meta "release=${release}" \
		-meta "commit=${commit}"
	timeline "phase=maintenance status=complete"
fi

if [[ "${database_needed}" == true ]]; then
	timeline "phase=database status=starting"
	dispatch_release_job rezics-release-database \
		"database:$(component_hash database)" \
		-meta "release=${release}" \
		-meta "commit=${commit}" \
		-meta "database_image=${database_image}"
	record_component database "$(component_hash database)" \
		"$(jq -cn --arg image "${database_image}" '{image: $image}')"
	timeline "phase=database status=complete"
fi

if [[ "${api_needed}" == true ]]; then
	timeline "phase=api status=starting"
	dispatch_release_job rezics-release-api-deploy \
		"api:$(component_hash api)" \
		-meta "release=${release}" \
		-meta "commit=${commit}" \
		-meta "image=${api_image}"
	record_component api "$(component_hash api)" \
		"$(jq -cn --arg image "${api_image}" '{image: $image}')"
	timeline "phase=api status=complete"
fi

if [[ "${worker_needed}" == true ]]; then
	timeline "phase=worker status=starting"
	dispatch_release_job rezics-release-worker-deploy \
		"worker:$(component_hash worker)" \
		-meta "release=${release}" \
		-meta "commit=${commit}" \
		-meta "image=${worker_image}"
	record_component worker "$(component_hash worker)" \
		"$(jq -cn --arg image "${worker_image}" '{image: $image}')"
	timeline "phase=worker status=complete"
fi

if [[ "${projection_needed}" == true ]]; then
	timeline "phase=projection status=starting"
	database_image="$(jq -er '.components.database.artifact.image' "${component_state_file}")"
	dispatch_release_job rezics-release-projection \
		"projection:$(component_hash projection)" \
		-meta "release=${release}" \
		-meta "commit=${commit}" \
		-meta "database_image=${database_image}"
	record_component projection "$(component_hash projection)" \
		"$(jq -cn --arg image "${database_image}" '{image: $image}')"
	timeline "phase=projection status=complete"
fi

state_file="$(mktemp "${state_directory}/.current-release.XXXXXX")"
jq -n \
	--arg release "${release}" \
	--arg commit "${commit}" \
	--arg installed_at "$(date --utc --iso-8601=seconds)" \
	--slurpfile component_state "${component_state_file}" \
	'{
	  schemaVersion: 2,
	  release: $release,
	  commit: $commit,
	  components: $component_state[0].components,
	  installedAt: $installed_at
	}' >"${state_file}"
chmod 0600 "${state_file}"
mv "${state_file}" "${current_release_file}"

printf 'Release %s deployed from %s\n' "${release}" "${commit}"
timeline "phase=release release=${release} commit=${commit} status=complete"
