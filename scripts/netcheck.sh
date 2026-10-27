# From \ To       api :5000   db :5432    cache :6379     Internet (1.1.1.1:443)
# proxy           Allowed      Blocked    Blocked         Allowed
# api             —            Allowed    Allowed         Allowed
# worker          Blocked      Allowed    Allowed         Blocked
# cache           Allowed      Allowed     —              Blocked
# db              Allowed      -           Allowed        Blocked    
# backup-job      Blocked      Allowed    Blocked         Blocked

#!/usr/bin/env bash

set -u

if ! command -v docker >/dev/null 2>&1; then
    echo "docker could not be found; install Docker and try again." >&2
    exit 1
fi

containers=(proxy api worker redis db backup)
for container in "${containers[@]}"; do
    if ! running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null); then
        echo "Container '$container' could not be inspected; start the project and try again." >&2
        exit 1
    fi
    if [[ "$running" != "true" ]]; then
        echo "Container '$container' is not running; start the project and try again." >&2
        exit 1
    fi
done

if ! docker image inspect busybox:1.36 >/dev/null 2>&1; then
    if ! docker pull busybox:1.36; then
        echo "Could not pull busybox:1.36, which is required for network checks." >&2
        exit 1
    fi
fi

probe() {
    local source="$1"
    local target="$2"
    local port="$3"

    if docker run --rm --network "container:$source" busybox:1.36 nc -zw3 "$target" "$port" >/dev/null 2>&1; then
        printf 'Allowed'
    else
        printf 'Blocked'
    fi
}

print_row() {
    local label="$1"
    local source="$2"
    local api_status db_status cache_status internet_status

    if [[ "$source" == "api" ]]; then
        api_status='—'
    else
        api_status=$(probe "$source" api 5000)
    fi
    if [[ "$source" == "db" ]]; then
        db_status='—'
    else
        db_status=$(probe "$source" db 5432)
    fi
    if [[ "$source" == "redis" ]]; then
        cache_status='—'
    else
        cache_status=$(probe "$source" redis 6379)
    fi
    internet_status=$(probe "$source" 1.1.1.1 443)

    printf '%-14s %-12s %-12s %-14s %s\n' \
        "$label" "$api_status" "$db_status" "$cache_status" "$internet_status"
}

printf '%-14s %-12s %-12s %-14s %s\n' \
    'From \ To' 'api :5000' 'db :5432' 'cache :6379' 'Internet (1.1.1.1:443)'

print_row proxy proxy
print_row api api
print_row worker worker
print_row cache redis
print_row db db
print_row backup-job backup
