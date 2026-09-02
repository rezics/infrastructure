#!/usr/bin/env bash

set -euo pipefail
umask 077

if (($# != 1)); then
	printf '%s\n' "Usage: generate-nomad-pki.sh <new-output-directory>" >&2
	exit 64
fi

readonly output_directory="$1"
if [[ -e "${output_directory}" ]]; then
	printf 'Output path already exists: %s\n' "${output_directory}" >&2
	exit 1
fi

if [[ "$(nomad version | sed -n '1s/^Nomad v//p')" != "2.0.4" ]]; then
	printf '%s\n' "Nomad 2.0.4 is required to generate the bootstrap bundle" >&2
	exit 1
fi

mkdir -p "${output_directory}/ca" "${output_directory}/install"
absolute_output="$(cd "${output_directory}" && pwd)"
readonly absolute_output

cd "${absolute_output}/ca"
nomad tls ca create -days=3650 -domain=nomad
nomad tls cert create \
	-server \
	-region=global \
	-days=825 \
	-ca=nomad-agent-ca.pem \
	-key=nomad-agent-ca-key.pem
nomad tls cert create \
	-cli \
	-days=825 \
	-ca=nomad-agent-ca.pem \
	-key=nomad-agent-ca-key.pem

install -m 0644 nomad-agent-ca.pem "${absolute_output}/install/nomad-agent-ca.pem"
install -m 0644 global-server-nomad.pem "${absolute_output}/install/global-server-nomad.pem"
install -m 0600 global-server-nomad-key.pem \
	"${absolute_output}/install/global-server-nomad-key.pem"
install -m 0644 global-cli-nomad.pem "${absolute_output}/install/global-cli-nomad.pem"
install -m 0600 global-cli-nomad-key.pem \
	"${absolute_output}/install/global-cli-nomad-key.pem"

gossip_key="$(nomad operator gossip keyring generate)"
readonly gossip_key
printf '{"server":{"encrypt":"%s"}}\n' "${gossip_key}" \
	>"${absolute_output}/install/cluster.json"

printf 'Nomad install bundle: %s\n' "${absolute_output}/install"
printf 'Offline CA material: %s\n' "${absolute_output}/ca"
printf '%s\n' "Copy only the install directory to the host; retain the ca directory offline."
