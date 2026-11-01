#!/usr/bin/env bash
# Stop and remove the Linkly containers and networks, and clear the firewall
# rules that up.sh added. Volumes (data) are kept unless you pass --volumes.
#
# Usage: sudo scripts/down.sh [--volumes]
set -euo pipefail

CONTAINERS=(proxy worker api redis db)   # front to back, so nothing gets new work mid-stop
NETWORKS=(dmz internal admin)
VOLUMES=(pgdata redisdata reports)
STOP_TIMEOUT=20                          # seconds each container gets to shut down cleanly

log()  { echo "[down] $*"; }
warn() { echo "[down] WARNING: $*" >&2; failed=1; }
die()  { echo "[down] ERROR: $*" >&2; exit 1; }

remove_volumes=0
case "${1:-}" in
    "") ;;
    --volumes) remove_volumes=1 ;;
    *) die "unknown option '$1' (usage: $0 [--volumes])" ;;
esac

[[ $EUID -eq 0 ]] || die "run as root (needed for docker and iptables)"
command -v docker &>/dev/null || die "docker not found"

failed=0

# ---------------------------------------------------------------------------
# Containers: stop gracefully first so Postgres shuts down cleanly, Redis
# flushes its append-only file and the worker finishes the click it's saving.
# ---------------------------------------------------------------------------
present=()
for c in "${CONTAINERS[@]}"; do
    docker inspect "$c" &>/dev/null && present+=("$c")
done

if (( ${#present[@]} )); then
    log "stopping ${present[*]} (up to ${STOP_TIMEOUT}s each)"
    docker stop -t "$STOP_TIMEOUT" "${present[@]}" >/dev/null || warn "some containers did not stop cleanly"
    for c in "${present[@]}"; do
        if docker rm -f "$c" >/dev/null; then
            log "removed container '$c'"
        else
            warn "could not remove container '$c'"
        fi
    done
else
    log "no Linkly containers found"
fi

# ---------------------------------------------------------------------------
# Networks: a network still used by another container (for example a running
# backup.sh or netcheck.sh job) can't be removed, so say which one is in the way.
# ---------------------------------------------------------------------------
for net in "${NETWORKS[@]}"; do
    docker network inspect "$net" &>/dev/null || continue
    if docker network rm "$net" >/dev/null 2>&1; then
        log "removed network '$net'"
    else
        users=$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net" 2>/dev/null || true)
        users="${users% }"
        warn "could not remove network '$net' (still used by: ${users:-unknown})"
    fi
done

# ---------------------------------------------------------------------------
# Firewall: put DOCKER-USER back to Docker's default (a single RETURN), so the
# DROP rules for the Linkly subnets don't outlive the networks.
# ---------------------------------------------------------------------------
if command -v iptables &>/dev/null && iptables -L DOCKER-USER -n &>/dev/null; then
    if iptables -F DOCKER-USER && iptables -A DOCKER-USER -j RETURN; then
        log "cleared firewall rules in DOCKER-USER"
    else
        warn "could not clear the DOCKER-USER firewall rules"
    fi
fi

# ---------------------------------------------------------------------------
# Volumes: only with --volumes. This deletes all links, clicks and reports.
# ---------------------------------------------------------------------------
if (( remove_volumes )); then
    for vol in "${VOLUMES[@]}"; do
        docker volume inspect "$vol" &>/dev/null || continue
        if docker volume rm "$vol" >/dev/null; then
            log "removed volume '$vol'"
        else
            warn "could not remove volume '$vol'"
        fi
    done
else
    log "volumes kept: ${VOLUMES[*]} (pass --volumes to delete them)"
fi

if (( failed )); then
    die "finished with warnings; check with: docker ps -a && docker network ls"
fi
log "done"
