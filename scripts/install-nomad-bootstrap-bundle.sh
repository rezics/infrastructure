#!/usr/bin/env bash

set -euo pipefail

if (($# != 1)) || [[ "$(id -u)" != 0 ]]; then
	printf '%s\n' "Usage as root: install-nomad-bootstrap-bundle.sh <install-directory>" >&2
	exit 64
fi

readonly source_directory="$1"
readonly required_files=(
	nomad-agent-ca.pem
	global-server-nomad.pem
	global-server-nomad-key.pem
	global-cli-nomad.pem
	global-cli-nomad-key.pem
	cluster.json
)

for file in "${required_files[@]}"; do
	if [[ ! -f "${source_directory}/${file}" ]]; then
		printf 'Missing bootstrap file: %s/%s\n' "${source_directory}" "${file}" >&2
		exit 1
	fi
done

getent passwd traefik >/dev/null
getent passwd rezics-deploy >/dev/null
getent passwd rezics-infrastructure-deploy >/dev/null

install -d -o root -g root -m 0700 /var/lib/nomad/tls /var/lib/nomad/secrets
install -o root -g root -m 0644 \
	"${source_directory}/nomad-agent-ca.pem" \
	"${source_directory}/global-server-nomad.pem" \
	/var/lib/nomad/tls/
install -o root -g root -m 0600 \
	"${source_directory}/global-server-nomad-key.pem" \
	/var/lib/nomad/tls/global-server-nomad-key.pem
install -o root -g root -m 0600 \
	"${source_directory}/cluster.json" \
	/var/lib/nomad/secrets/cluster.json
jq -n '{auths: {}}' >/var/lib/nomad/secrets/docker-config.json
chmod 0600 /var/lib/nomad/secrets/docker-config.json

for owner in traefik rezics-deploy rezics-infrastructure-deploy; do
	readonly_target="/var/lib/${owner}/nomad-tls"
	install -d -o "${owner}" -g "${owner}" -m 0700 "${readonly_target}"
	install -o "${owner}" -g "${owner}" -m 0644 \
		"${source_directory}/nomad-agent-ca.pem" \
		"${source_directory}/global-cli-nomad.pem" \
		"${readonly_target}/"
	install -o "${owner}" -g "${owner}" -m 0600 \
		"${source_directory}/global-cli-nomad-key.pem" \
		"${readonly_target}/global-cli-nomad-key.pem"
done

# Reapply declarative ACLs after the credential files have been installed.
systemd-tmpfiles --create --prefix=/var/lib/rezics-deploy/nomad-tls

systemctl restart nomad.service
systemctl --no-pager --full status nomad.service
