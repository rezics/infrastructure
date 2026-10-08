#!/usr/bin/env bash
set -euo pipefail
umask 077
readonly data_dir="${STALWART_DATA_DIR:?}"
readonly admin_hash="${STALWART_ADMIN_HASH_FILE:?}"
mkdir -p /var/lib/stalwart-backup/.temp
work="$(mktemp -d /var/lib/stalwart-backup/.temp/mail.XXXXXX)"
quiesced=false
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$quiesced" == true ]]; then systemctl start stalwart.service || status=70; fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT INT TERM
systemctl is-active --quiet stalwart.service
systemctl stop stalwart.service
quiesced=true
mkdir "$work/snapshot"
cp -a --reflink=auto "$data_dir" "$work/snapshot/stalwart"
cp "$admin_hash" "$work/snapshot/admin-password-hash"
systemctl start stalwart.service
quiesced=false
(
  cd "$work/snapshot"
  find . -type f -print0 | sort -z | xargs -0 sha256sum > "$work/manifest"
  mv "$work/manifest" SHA256SUMS
)
if ! restic --no-lock --no-cache snapshots >/dev/null 2>&1; then restic init; fi
restic --no-lock --no-cache backup --tag stalwart-mail --host B "$work/snapshot"
restic --no-lock --no-cache check --read-data
restic --no-lock --no-cache restore latest --tag stalwart-mail --target "$work/restored"
manifest="$(find "$work/restored" -name SHA256SUMS -type f)"
[[ -n "$manifest" ]]
(cd "$(dirname "$manifest")"; sha256sum --check SHA256SUMS)
printf 'Stalwart encrypted off-host backup and restore-byte verification completed\n'
