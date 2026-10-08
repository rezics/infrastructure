#!/usr/bin/env bash
set -euo pipefail

# Databasus owns this state. Keep its recovery history and Outline scheduling.
container=''
for _attempt in $(seq 1 60); do
  container="$(docker ps --filter name=databasus --format '{{.ID}}' | head -n 1)"
  if [[ -n "$container" ]] && docker exec "$container" \
    psql -h 127.0.0.1 -p 5437 -U postgres -d databasus -Atqc 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
[[ -n "$container" ]]
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5437 -U postgres -d databasus <<'SQL'
BEGIN;
UPDATE logical_backup_configs SET is_backups_enabled = false
WHERE database_id IN (SELECT id FROM databases WHERE name = 'rezics');
UPDATE physical_backup_configs SET is_backups_enabled = false,
  force_full_requested_at = NULL, force_incremental_requested_at = NULL
WHERE database_id IN (SELECT id FROM databases WHERE name = 'rezics');
UPDATE backup_verification_configs SET is_scheduled_verification_enabled = false
WHERE database_id IN (SELECT id FROM databases WHERE name = 'rezics');
COMMIT;
SELECT d.name, l.is_backups_enabled, v.is_scheduled_verification_enabled
FROM databases d LEFT JOIN logical_backup_configs l ON l.database_id = d.id
LEFT JOIN backup_verification_configs v ON v.database_id = d.id
WHERE d.name IN ('rezics', 'outline') ORDER BY d.name;
SQL
