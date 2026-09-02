#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly base_url="${REZICS_SIGNOZ_URL:-http://127.0.0.1:3080}"
readonly root_email_file="${REZICS_SIGNOZ_ROOT_EMAIL_FILE:?}"
readonly root_password_file="${REZICS_SIGNOZ_ROOT_PASSWORD_FILE:?}"
readonly root_org_id_file="${REZICS_SIGNOZ_ROOT_ORG_ID_FILE:?}"
readonly dashboard_files="${REZICS_SIGNOZ_DASHBOARD_FILES:?}"

for required_file in \
	"${root_email_file}" \
	"${root_password_file}" \
	"${root_org_id_file}"; do
	if [[ ! -r "${required_file}" || ! -s "${required_file}" ]]; then
		printf 'Required SigNoz provisioning input is unavailable: %s\n' \
			"${required_file}" >&2
		exit 1
	fi
done

for _ in $(seq 1 60); do
	if curl --fail --silent --show-error --max-time 5 \
		"${base_url}/api/v1/health" >/dev/null 2>&1; then
		break
	fi
	sleep 5
done
curl --fail --silent --show-error --max-time 5 \
	"${base_url}/api/v1/health" >/dev/null

root_email="$(<"${root_email_file}")"
root_password="$(<"${root_password_file}")"
root_org_id="$(<"${root_org_id_file}")"
login_response="$({
	jq -n \
		--arg email "${root_email}" \
		--arg password "${root_password}" \
		--arg orgId "${root_org_id}" \
		'{email: $email, password: $password, orgId: $orgId}'
} | curl --fail --silent --show-error --max-time 15 \
	-H 'Content-Type: application/json' \
	--data-binary @- \
	"${base_url}/api/v2/sessions/email_password")"
access_token="$(jq -er '.data.accessToken' <<<"${login_response}")"

cleanup_session() {
	curl --fail --silent --show-error --max-time 10 \
		-X DELETE \
		-H "Authorization: Bearer ${access_token}" \
		"${base_url}/api/v2/sessions" >/dev/null 2>&1 || true
}
trap cleanup_session EXIT

get_retention() {
	local signal="$1"
	local response current current_hours status
	if [[ "${signal}" == "logs" ]]; then
		response="$(curl --fail --silent --show-error --max-time 30 \
			-H "Authorization: Bearer ${access_token}" \
			"${base_url}/api/v2/settings/ttl")"
		current="$(jq -er '.default_ttl_days' <<<"${response}")"
	else
		response="$(curl --fail --silent --show-error --max-time 30 \
			-H "Authorization: Bearer ${access_token}" \
			"${base_url}/api/v1/settings/ttl?type=${signal}")"
		current_hours="$(jq -er --arg key "${signal}_ttl_duration_hrs" '.[$key]' \
			<<<"${response}")"
		current=-1
		if ((current_hours >= 0 && current_hours % 24 == 0)); then
			current="$((current_hours / 24))"
		fi
	fi
	status="$(jq -er '.status' <<<"${response}")"
	printf '%s\t%s\n' "${current}" "${status}"
}

set_retention() {
	local signal="$1"
	local days="$2"
	local current status
	IFS=$'\t' read -r current status < <(get_retention "${signal}")
	if [[ "${current}" == "${days}" && "${status}" == "success" ]]; then
		printf 'SigNoz %s retention already equals %s days\n' "${signal}" "${days}"
		return
	fi
	if [[ "${signal}" == "logs" ]]; then
		jq -n --arg type "${signal}" --argjson days "${days}" \
			'{type: $type, defaultTTLDays: $days, ttlConditions: []}' |
			curl --fail --silent --show-error --max-time 600 \
				-X POST \
				-H "Authorization: Bearer ${access_token}" \
				-H 'Content-Type: application/json' \
				--data-binary @- \
				"${base_url}/api/v2/settings/ttl" >/dev/null
	else
		curl --fail --silent --show-error --max-time 600 \
			-X POST \
			-H "Authorization: Bearer ${access_token}" \
			"${base_url}/api/v1/settings/ttl?duration=$((days * 24))h&type=${signal}" \
			>/dev/null
	fi
	for _ in $(seq 1 120); do
		IFS=$'\t' read -r current status < <(get_retention "${signal}")
		if [[ "${current}" == "${days}" && "${status}" == "success" ]]; then
			printf 'Set SigNoz %s retention to %s days\n' "${signal}" "${days}"
			return
		fi
		if [[ "${status}" == "failed" ]]; then
			printf 'SigNoz %s retention update failed\n' "${signal}" >&2
			return 1
		fi
		sleep 5
	done
	printf 'Timed out waiting for SigNoz %s retention to reach %s days\n' \
		"${signal}" "${days}" >&2
	return 1
}

set_retention traces 7
set_retention metrics 30
set_retention logs 7

dashboards_response="$(curl --fail --silent --show-error --max-time 30 \
	-H "Authorization: Bearer ${access_token}" \
	"${base_url}/api/v2/dashboards?limit=100&offset=0")"
IFS=':' read -r -a dashboards <<<"${dashboard_files}"
for dashboard_file in "${dashboards[@]}"; do
	if [[ ! -r "${dashboard_file}" ]]; then
		printf 'SigNoz dashboard definition is unavailable: %s\n' \
			"${dashboard_file}" >&2
		exit 1
	fi
	display_name="$(jq -er '.spec.display.name' "${dashboard_file}")"
	if jq -e --arg display_name "${display_name}" \
		'any(.data.dashboards[]?; .spec.display.name == $display_name)' \
		<<<"${dashboards_response}" >/dev/null; then
		printf 'SigNoz dashboard already exists: %s\n' "${display_name}"
		continue
	fi
	curl --fail --silent --show-error --max-time 60 \
		-X POST \
		-H "Authorization: Bearer ${access_token}" \
		-H 'Content-Type: application/json' \
		--data-binary "@${dashboard_file}" \
		"${base_url}/api/v2/dashboards" >/dev/null
	printf 'Created SigNoz dashboard: %s\n' "${display_name}"
	dashboards_response="$(curl --fail --silent --show-error --max-time 30 \
		-H "Authorization: Bearer ${access_token}" \
		"${base_url}/api/v2/dashboards?limit=100&offset=0")"
done

printf '%s\n' 'SigNoz retention and dashboards are reconciled'
