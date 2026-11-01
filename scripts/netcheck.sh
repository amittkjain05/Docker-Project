#!/usr/bin/env bash
# Test every cell of the reachability matrix from inside each service's network namespace.
# Exits non-zero if any cell differs from the expected result.
set -euo pipefail

PROBE_IMAGE="python:3.12-slim-bookworm"
PROBE='
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    ip = socket.gethostbyname(host)
except OSError:
    print("no-dns"); sys.exit(0)
try:
    socket.create_connection((ip, port), 3).close(); print("open")
except OSError:
    print("timeout")
'

# source  target   port  expected
MATRIX="
proxy   api      5000  allowed
proxy   db       5432  blocked
proxy   cache    6379  blocked
proxy   1.1.1.1  443   allowed
api     db       5432  allowed
api     cache    6379  allowed
api     1.1.1.1  443   allowed
worker  api      5000  allowed
worker  db       5432  allowed
worker  cache    6379  allowed
worker  1.1.1.1  443   blocked
cache   api      5000  allowed
cache   db       5432  allowed
cache   1.1.1.1  443   blocked
db      api      5000  allowed
db      cache    6379  allowed
db      1.1.1.1  443   blocked
backup  api      5000  blocked
backup  db       5432  allowed
backup  cache    6379  blocked
backup  1.1.1.1  443   blocked
"

probe() { # source target port
  local net
  if [ "$1" = "backup" ]; then
    net="admin"            # the backup job is a throwaway container on admin only
  else
    net="container:$1"     # share the running service's network namespace
  fi
  docker run --rm --network "$net" --cap-drop ALL "$PROBE_IMAGE" python -c "$PROBE" "$2" "$3"
}

fail=0
printf '%-8s %-8s %-6s %-9s %-9s %s\n' FROM TO PORT EXPECTED ACTUAL RESULT
while read -r src dst port expected; do
  [ -z "$src" ] && continue
  result="$(probe "$src" "$dst" "$port")"
  if [ "$result" = "open" ]; then actual="allowed"; else actual="blocked"; fi
  if [ "$actual" = "$expected" ]; then mark="PASS"; else mark="FAIL"; fail=1; fi
  printf '%-8s %-8s %-6s %-9s %-9s %s (%s)\n' "$src" "$dst" "$port" "$expected" "$actual" "$mark" "$result"
done <<< "$MATRIX"

exit "$fail"
