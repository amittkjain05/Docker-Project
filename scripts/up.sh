#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Settings (change these in one place)
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/amittkjain05/Docker-Project.git"
REPO_DIR="Docker-Project"
IMAGE_REPO="https://hub.docker.com/repository/docker/amitjain6/linkly_app"
#APP_TAG="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
APP_TAG="67f6b8d"
SECRETS_DIR="/secrets"
WAIT_TIMEOUT=60
#API_IMAGE="${API_IMAGE:-linkly-api:$TAG}"
#WORKER_IMAGE="${WORKER_IMAGE:-linkly-worker:$TAG}"
PROXY_IMAGE="nginxinc/nginx-unprivileged:1.27-alpine"
DB_IMAGE="postgres:16-alpine"
REDIS_IMAGE="redis:7.4-alpine"   # seconds to wait for each container to come up

# Network subnets and fixed container IPs (firewall rules depend on these)
DMZ_CIDR="172.30.1.0/24"
INT_CIDR="172.30.2.0/24"
ADMIN_CIDR="172.30.3.0/24"

PROXY_IP="172.30.1.10"     # dmz
API_DMZ_IP="172.30.1.11"   # dmz
DB_IP="172.30.2.10"        # internal
REDIS_IP="172.30.2.11"     # internal
API_INT_IP="172.30.2.12"   # internal
WORKER_IP="172.30.2.13"    # internal
# Backups are not a long-running service: scripts/backup.sh runs a throwaway
# pg_dump container on the admin network (db is also attached to admin).

# Options shared by every container
COMMON_OPTS=(
    --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID
    --security-opt no-new-privileges
    --read-only
    --memory 256m --cpus 0.5
    --log-opt max-size=10m --log-opt max-file=3
    --restart unless-stopped
)
# Options shared by some containers
TMPFS_TMP=(--tmpfs /tmp:rw,noexec,nosuid,size=100m,mode=1777)
SECRETS_MOUNT=(--mount "type=bind,source=${SECRETS_DIR},target=/run/secrets,readonly")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[up] $*"; }
die() { echo "[up] ERROR: $*" >&2; exit 1; }

for f in DB_PASSWORD POSTGRES_PASSWORD; do
    [[ -f "$SECRETS_DIR/$f" ]] || die "missing $SECRETS_DIR/$f"
done


# True if the container is running and, when it has a healthcheck, healthy.
is_container_up() {
    local name="$1" running health
    read -r running health < <(docker inspect -f \
        '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        "$name" 2>/dev/null) || return 1
    [[ "$running" == "true" && ( -z "${health:-}" || "$health" == "healthy" ) ]]
}

# Wait until a container is up; stop the script if it exits or times out.
wait_for_container() {
    local name="$1" timeout="${2:-$WAIT_TIMEOUT}" waited=0
    until is_container_up "$name"; do
        if [[ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" == "exited" ]]; then
            docker logs --tail 20 "$name" >&2 || true
            die "container '$name' exited during startup"
        fi
        (( waited >= timeout )) && die "container '$name' not up after ${timeout}s"
        sleep 2; (( waited += 2 ))
    done
    log "container '$name' is up"
}

# Start a container with the common options, then wait for it.
# Usage: run_container <name> <network> [extra docker run args...] <image> [cmd...]
run_container() {
    local name="$1" network="$2"; shift 2
    if is_container_up "$name"; then
        log "container '$name' already up, skipping"
        return
    fi
    docker rm -f "$name" &>/dev/null || true   # clear a stopped/failed old copy
    log "starting '$name'"
    docker run -d --name "$name" --network "$network" "${COMMON_OPTS[@]}" "$@" >/dev/null
    wait_for_container "$name"
}

# Attach a container to an extra network if it isn't attached already.
# Usage: connect_network <network> <name> [fixed ip]
connect_network() {
    local network="$1" name="$2" ip="${3:-}"
    if [[ -z "$(docker inspect -f "{{index .NetworkSettings.Networks \"$network\"}}" "$name" 2>/dev/null | grep -v '<no value>')" ]]; then
        docker network connect ${ip:+--ip "$ip"} "$network" "$name"
    fi
}

# Create a network if it doesn't exist; stop if it exists with a different subnet.
# Usage: ensure_network <name> <subnet> [create args...]
ensure_network() {
    local name="$1" subnet="$2" current; shift 2
    if docker network inspect "$name" &>/dev/null; then
        current=$(get_cidr "$name")
        [[ "$current" == "$subnet" ]] || die "network '$name' has subnet $current, expected $subnet; remove it (docker network rm $name) and re-run"
    else
        docker network create --driver bridge --subnet "$subnet" "$@" "$name" >/dev/null
    fi
}

ensure_volume() {
    docker volume inspect "$1" &>/dev/null || docker volume create "$1" >/dev/null
}

# IP of a container on a given network (fails if missing).
get_ip() {
    local ip
    ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"$2\"}}{{.IPAddress}}{{end}}" "$1")
    [[ -n "$ip" ]] || die "no IP for '$1' on network '$2'"
    echo "$ip"
}

get_cidr() {
    docker network inspect "$1" -f '{{(index .IPAM.Config 0).Subnet}}'
}

# Stop if a container's IP isn't the fixed one the firewall rules expect
# (e.g. an old container from before fixed IPs that run_container skipped).
check_ip() {
    local name="$1" network="$2" expected="$3" actual
    actual=$(get_ip "$name" "$network")
    [[ "$actual" == "$expected" ]] || die "'$name' has IP $actual on $network, expected $expected; remove it (docker rm -f $name) and re-run"
}

# Allow new connections from one IP to another.
allow() {
    iptables -A DOCKER-USER -s "$1" -d "$2" -m conntrack --ctstate NEW -j ACCEPT
}

# ---------------------------------------------------------------------------
# Pre-checks
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run as root (needed for docker install, modprobe and iptables)"

if [[ ! -d "$REPO_DIR" ]]; then
    git clone "$REPO_URL" "$REPO_DIR" || die "failed to clone repository; check your connection"
fi

# Proxy config and certificates are bind-mounted, so they must exist (absolute path needed).
# proxy/certs/ is in .gitignore, so a fresh clone won't have the certificates.
PROXY_DIR="$(cd "$REPO_DIR/proxy" && pwd)" || die "no proxy/ folder in $REPO_DIR"
for f in default.conf certs/tls.crt certs/tls.key; do
    [[ -f "$PROXY_DIR/$f" ]] || die "missing $PROXY_DIR/$f (TLS certificates must be copied or generated there)"
done

if ! command -v docker &>/dev/null; then
    log "docker not found, installing..."
    apt-get update && apt-get install -y docker.io
    systemctl enable --now docker || true
fi

# ---------------------------------------------------------------------------
# Networks and volumes
# ---------------------------------------------------------------------------
ensure_network dmz      "$DMZ_CIDR"
ensure_network internal "$INT_CIDR"   --internal
ensure_network admin    "$ADMIN_CIDR" --internal

for vol in reports redisdata pgdata; do
    ensure_volume "$vol"
done

# ---------------------------------------------------------------------------
# Services (in dependency order: db -> redis -> api -> worker -> proxy)
# ---------------------------------------------------------------------------
run_container db internal --ip "$DB_IP" \
    --tmpfs /var/run/postgresql:rw,noexec,nosuid,size=10m \
    "${TMPFS_TMP[@]}" \
    --mount type=volume,source=pgdata,target=/var/lib/postgresql/data \
    "${SECRETS_MOUNT[@]}" \
    -e POSTGRES_USER=linkly \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/POSTGRES_PASSWORD \
    -e POSTGRES_DB=linkly \
    --health-cmd 'pg_isready -U linkly -d linkly' --health-interval 5s --health-retries 12 \
    "$DB_IMAGE"
connect_network admin db

run_container redis internal --ip "$REDIS_IP" \
    --mount type=volume,source=redisdata,target=/data \
    --user redis \
    --health-cmd 'redis-cli ping' --health-interval 5s --health-retries 12 \
    "$REDIS_IMAGE" redis-server --appendonly yes --appendfsync everysec

run_container api internal --ip "$API_INT_IP" \
    -e DB_HOST=db -e REDIS_HOST=redis -e DB_PASSWORD_FILE=/run/secrets/DB_PASSWORD \
    "${SECRETS_MOUNT[@]}" \
    "${IMAGE_REPO}:api_app-${APP_TAG}"
connect_network dmz api "$API_DMZ_IP"

run_container worker internal --ip "$WORKER_IP" --init \
     -e DB_HOST=db -e REDIS_HOST=redis -e DB_PASSWORD_FILE=/run/secrets/DB_PASSWORD \
    "${TMPFS_TMP[@]}" \
    --mount type=volume,source=reports,target=/app/reports \
    -e WEBHOOK_URL= \
    "${SECRETS_MOUNT[@]}" \
    "${IMAGE_REPO}:worker-${APP_TAG}"

run_container proxy dmz --ip "$PROXY_IP" \
    "${TMPFS_TMP[@]}" \
    -p 80:8080 -p 443:8443 \
    --mount "type=bind,source=$PROXY_DIR/default.conf,target=/etc/nginx/conf.d/default.conf,readonly" \
    --mount "type=bind,source=$PROXY_DIR/certs/tls.crt,target=/etc/nginx/certs/tls.crt,readonly" \
    --mount "type=bind,source=$PROXY_DIR/certs/tls.key,target=/etc/nginx/certs/tls.key,readonly" \
    --health-cmd 'wget -q -O /dev/null http://127.0.0.1:8080/healthz' --health-interval 5s --health-retries 12 \
    "$PROXY_IMAGE"

# Final check: every service must be up before firewall rules are applied
for c in db redis api worker proxy; do
    is_container_up "$c" || die "container '$c' is not up"
done

# ---------------------------------------------------------------------------
# Firewall (DOCKER-USER chain)
# ---------------------------------------------------------------------------
modprobe br_netfilter || true
sysctl -w net.bridge.bridge-nf-call-iptables=1

# Make sure every container has the fixed IP the rules below are written for
check_ip proxy  dmz      "$PROXY_IP"
check_ip api    dmz      "$API_DMZ_IP"
check_ip api    internal "$API_INT_IP"
check_ip redis  internal "$REDIS_IP"
check_ip db     internal "$DB_IP"
check_ip worker internal "$WORKER_IP"

iptables -F DOCKER-USER

# Allow replies on existing connections, and Docker's internal DNS
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
for proto in udp tcp; do
    iptables -A DOCKER-USER -p "$proto" --dport 53 -j ACCEPT
done

# Allowed service-to-service traffic
allow "$PROXY_IP"   "$API_DMZ_IP"   # proxy  -> api
allow "$API_INT_IP" "$REDIS_IP"     # api    -> redis
allow "$API_INT_IP" "$DB_IP"        # api    -> db
allow "$WORKER_IP"  "$REDIS_IP"     # worker -> redis
allow "$WORKER_IP"  "$DB_IP"        # worker -> db (worker.py reads from Postgres)
# backup -> db goes over the admin network (only db and the backup job are on it),
# so it needs no rule here.

# Drop everything else between and within the dmz and internal networks
for src in "$DMZ_CIDR" "$INT_CIDR"; do
    for dst in "$DMZ_CIDR" "$INT_CIDR"; do
        iptables -A DOCKER-USER -s "$src" -d "$dst" -j DROP
    done
done

# Everything else goes back to Docker's normal handling
iptables -A DOCKER-USER -j RETURN

log "all services up and firewall rules applied"
