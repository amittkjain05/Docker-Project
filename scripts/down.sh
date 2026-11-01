#!/usr/bin/env bash
# Remove the Linkly containers and networks. Volumes (data) are kept.
set -euo pipefail

docker rm -f proxy worker api cache db >/dev/null 2>&1 || true
for net in dmz internal admin; do
  docker network rm "$net" >/dev/null 2>&1 || true
done
echo "Containers and networks removed. Volumes kept: pgdata, redisdata, reports."
