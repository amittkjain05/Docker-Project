#!/usr/bin/env bash
# Back up the Linkly database with pg_dump.
# Runs a throwaway postgres:16-alpine container on the admin network only and
# writes a timestamped, gzipped SQL dump to ./backups (at the repo root).
set -euo pipefail

BACKUP_IMAGE="postgres:16-alpine"
NETWORK="admin"
DB_HOST="pgsql"
DB_NAME="linkly"
DB_USER="linkly"
SECRETS_DIR="$(cd "$(dirname "$0")/.." && pwd)/secrets"   # same as up.sh
BACKUP_DIR="$(cd "$(dirname "$0")/.." && pwd)/backups"

log() { echo "[backup] $*"; }
die() { echo "[backup] ERROR: $*" >&2; exit 1; }

[[ -f "$SECRETS_DIR/DB_PASSWORD" ]] || die "missing $SECRETS_DIR/DB_PASSWORD"

# The pgsql container must be running and attached to the admin network.
[[ "$(docker inspect -f '{{.State.Running}}' "$DB_HOST" 2>/dev/null)" == "true" ]] \
    || die "container '$DB_HOST' is not running; start the stack with scripts/up.sh first"
[[ -n "$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NETWORK\"}}{{.IPAddress}}{{end}}" "$DB_HOST")" ]] \
    || die "container '$DB_HOST' is not on the '$NETWORK' network"

mkdir -p "$BACKUP_DIR"
FILE="linkly-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

log "dumping '$DB_NAME' to $BACKUP_DIR/$FILE"
# Write to a .partial file first so a failed dump never looks like a good backup.
docker run --rm \
    --network "$NETWORK" \
    --user "$(id -u):$(id -g)" \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --memory 256m --cpus 0.5 \
    --mount "type=bind,source=$SECRETS_DIR/DB_PASSWORD,target=/run/secrets/DB_PASSWORD,readonly" \
    --mount "type=bind,source=$BACKUP_DIR,target=/backups" \
    -e DB_HOST="$DB_HOST" -e DB_NAME="$DB_NAME" -e DB_USER="$DB_USER" -e FILE="$FILE" \
    "$BACKUP_IMAGE" \
    sh -c '
        set -eu
        set -o pipefail
        PGPASSWORD="$(cat /run/secrets/DB_PASSWORD)"
        export PGPASSWORD
        pg_dump -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" --no-owner \
            | gzip -9 > "/backups/$FILE.partial"
        mv "/backups/$FILE.partial" "/backups/$FILE"
    ' || { rm -f "$BACKUP_DIR/$FILE.partial"; die "pg_dump failed"; }

log "done: $BACKUP_DIR/$FILE ($(du -h "$BACKUP_DIR/$FILE" | cut -f1))"
