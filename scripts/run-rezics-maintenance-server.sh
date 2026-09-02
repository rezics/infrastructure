#!/usr/bin/env bash

set -euo pipefail

readonly listen_host="${REZICS_MAINTENANCE_HOST:?}"
readonly listen_port="${REZICS_MAINTENANCE_PORT:?}"

if [[ "${listen_host}" != 127.0.0.1 ]] ||
	[[ ! "${listen_port}" =~ ^[0-9]+$ ]] ||
	((listen_port < 1 || listen_port > 65535)); then
	printf 'Invalid maintenance listener: %s:%s\n' \
		"${listen_host}" "${listen_port}" >&2
	exit 64
fi

exec socat \
	"TCP4-LISTEN:${listen_port},bind=${listen_host},fork,reuseaddr" \
	"EXEC:/run/current-system/sw/bin/run-rezics-maintenance-response"
