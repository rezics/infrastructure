#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly workspace_id="${NOMAD_META_workspace_id:?}"
readonly release="${NOMAD_META_release:?}"
readonly commit="${NOMAD_META_commit:?}"
readonly components="${NOMAD_META_components:?}"
readonly state_directory="${REZICS_RELEASE_STATE_DIRECTORY:-/var/lib/rezics-release}"

if [[ ! "${workspace_id}" =~ ^[0-9a-f-]{36}$ ]] ||
	[[ ! "${release}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	[[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]] ||
	[[ ! "${components}" =~ ^(database|api|worker)(,(database|api|worker))*$ ]]; then
	printf '%s\n' "Release build metadata is malformed" >&2
	exit 64
fi

readonly repository="${state_directory}/workspaces/${workspace_id}/workload"
grant_controller_access() {
	local path
	for path in \
		"${repository}/.rezics-release-artifacts" \
		"${repository}/.rezics-release-build.json"; do
		if [[ -e "${path}" ]]; then
			setfacl --recursive --modify user:0:rwX "${path}" || true
		fi
	done
}
trap grant_controller_access EXIT
install -d -m 0700 "${HOME}" "${TMPDIR}"
git config --global --add safe.directory "${repository}"
if [[ ! -d "${repository}/.git" ]] ||
	[[ "$(git -C "${repository}" rev-parse 'HEAD^{commit}')" != "${commit}" ]]; then
	printf '%s\n' "Release build workspace does not match the dispatched commit" >&2
	exit 1
fi

"${repository}/deploy/scripts/build-release-artifacts.sh" \
	"${release}" "${commit}" "${components}" \
	"${repository}/.rezics-release-build.json"
