#!/usr/bin/env bash

set -euo pipefail

if ! IFS=' ' read -r _method request_target _protocol; then
	exit 0
fi
request_target="${request_target%$'\r'}"

while IFS= read -r header; do
	header="${header%$'\r'}"
	[[ -z "${header}" ]] && break
done

readonly request_path="${request_target%%\?*}"
if [[ "${request_path}" == /_health ]]; then
	readonly status='200 OK'
	readonly body='{"status":"maintenance-ready"}'
else
	readonly status='503 Service Unavailable'
	readonly body='{"error":"service_unavailable","message":"REZICS API is temporarily unavailable for scheduled maintenance."}'
fi

printf 'HTTP/1.1 %s\r\n' "${status}"
printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Content-Length: %s\r\n' "${#body}"
printf 'Cache-Control: no-store\r\n'
printf 'Connection: close\r\n'
if [[ "${status}" == '503 Service Unavailable' ]]; then
	printf 'Retry-After: 60\r\n'
fi
printf '\r\n%s' "${body}"
