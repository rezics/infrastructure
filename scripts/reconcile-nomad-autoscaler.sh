#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly management_token_file="${REZICS_NOMAD_MANAGEMENT_TOKEN_FILE:?}"
readonly autoscaler_token_file="${REZICS_NOMAD_AUTOSCALER_TOKEN_FILE:?}"

if [[ ! -r "${management_token_file}" ]]; then
	printf 'Nomad management credential is not readable\n' >&2
	exit 1
fi

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

cat >"${temporary_directory}/autoscaler.hcl" <<'EOF'
namespace "rezics" {
  policy = "scale"
}
EOF

nomad acl policy apply \
	-description "Scale REZICS workloads only within their declared bounds" \
	rezics-autoscaler "${temporary_directory}/autoscaler.hcl" >/dev/null

if [[ -s "${autoscaler_token_file}" ]]; then
	candidate_token="$(<"${autoscaler_token_file}")"
	if token_json="$(
		NOMAD_TOKEN="${candidate_token}" nomad acl token self -json 2>/dev/null
	)" && jq -e '
		.Type == "client" and
		(.Policies | index("rezics-autoscaler") != null)
	' <<<"${token_json}" >/dev/null; then
		exit 0
	fi
fi

token_json="$(
	nomad acl token create \
		-name "REZICS Nomad Autoscaler" \
		-type client \
		-global \
		-policy rezics-autoscaler \
		-json
)"
jq -er '.SecretID' <<<"${token_json}" >"${temporary_directory}/nomad.token"
install -D -m 0400 -o root -g root \
	"${temporary_directory}/nomad.token" "${autoscaler_token_file}"
