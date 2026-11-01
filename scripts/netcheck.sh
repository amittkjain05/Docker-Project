#!/usr/bin/env bash
# Test every cell of the reachability matrix from inside each service's network namespace.
# Exits non-zero if any cell differs from the expected result.
#
# The expected results match the firewall that scripts/up.sh applies, so run
# this after up.sh has finished.
#
# Usage: sudo scripts/netcheck.sh
set -euo pipefail

PROBE_IMAGE="python:3.12-slim-bookworm"
SERVICES=(proxy api worker redis pgsql)

# Prints one word: "open", "no-dns" (name doesn't resolve on this network),
# "timeout" (packets dropped), "refused", "unreachable" (no route), or the error name.
PROBE='
import errno, socket, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    ip = socket.gethostbyname(host)
except OSError:
    print("no-dns"); sys.exit(0)
try:
    socket.create_connection((ip, port), 3).close(); print("open")
except socket.timeout:
    print("timeout")
except ConnectionRefusedError:
    print("refused")
except OSError as e:
    print("unreachable" if e.errno in (errno.ENETUNREACH, errno.EHOSTUNREACH) else type(e).__name__)
'

# What up.sh sets up:
# - proxy is on dmz; api is on dmz and internal; worker, redis and pgsql are on
#   internal (no internet); pgsql is also on admin (no internet).
# - The firewall only allows proxy->api, api->redis, api->pgsql, worker->redis and
#   worker->pgsql between dmz and internal. Everything else between them is dropped.
# - The backup job (backup.sh) is a throwaway container on admin only.
#
# source  target   port  expected
MATRIX="
proxy   api      5000  allowed
proxy   pgsql    5432  blocked
proxy   redis    6379  blocked
proxy   1.1.1.1  443   allowed
api     pgsql    5432  allowed
api     redis    6379  allowed
api     1.1.1.1  443   allowed
worker  api      5000  blocked
worker  pgsql    5432  allowed
worker  redis    6379  allowed
worker  1.1.1.1  443   blocked
redis   api      5000  blocked
redis   pgsql    5432  blocked
redis   1.1.1.1  443   blocked
pgsql   api      5000  blocked
pgsql   redis    6379  blocked
pgsql   1.1.1.1  443   blocked
backup  api      5000  blocked
backup  pgsql    5432  allowed
backup  redis    6379  blocked
backup  1.1.1.1  443   blocked
"

die() { echo "[netcheck] ERROR: $*" >&2; exit 2; }

command -v docker &>/dev/null || die "docker not found"
docker info &>/dev/null || die "can't talk to Docker; run as root (sudo)"

# Every service must be running, or its rows would all fail for the wrong reason.
missing=()
for c in "${SERVICES[@]}"; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]] || missing+=("$c")
done
(( ${#missing[@]} == 0 )) || die "not running: ${missing[*]} (start the stack with scripts/up.sh first)"
docker network inspect admin &>/dev/null || die "network 'admin' not found (start the stack with scripts/up.sh first)"

# Pull once up front so the first probe isn't slowed down or mixed with pull output.
docker image inspect "$PROBE_IMAGE" &>/dev/null || docker pull -q "$PROBE_IMAGE" >/dev/null \
    || die "could not pull $PROBE_IMAGE"

probe() { # source target port
    local net
    if [[ "$1" == "backup" ]]; then
        net="admin"            # the backup job is a throwaway container on admin only
    else
        net="container:$1"     # share the running service's network namespace
    fi
    docker run --rm --network "$net" --cap-drop ALL --read-only \
        "$PROBE_IMAGE" python -c "$PROBE" "$2" "$3" </dev/null 2>/dev/null
}

fail=0
printf '%-8s %-8s %-6s %-9s %-9s %s\n' FROM TO PORT EXPECTED ACTUAL RESULT
while read -r src dst port expected; do
    [[ -z "$src" ]] && continue
    # A failed docker run counts as a FAIL for this row instead of ending the script.
    result="$(probe "$src" "$dst" "$port")" || result="probe-error"
    result="${result:-probe-error}"
    if [[ "$result" == "open" ]]; then actual="allowed"; else actual="blocked"; fi
    if [[ "$result" != "probe-error" && "$actual" == "$expected" ]]; then
        mark="PASS"
    else
        mark="FAIL"; fail=1
    fi
    printf '%-8s %-8s %-6s %-9s %-9s %s (%s)\n' "$src" "$dst" "$port" "$expected" "$actual" "$mark" "$result"
done <<< "$MATRIX"

if (( fail )); then
    echo "[netcheck] some checks FAILED"
else
    echo "[netcheck] all checks passed"
fi
exit "$fail"
