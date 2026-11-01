# Linkly

Linkly is a small link shortener deployed as a set of hardened Docker containers.
There is no Docker Compose file: plain bash scripts create the networks, start the
containers in order and lock down traffic between them with iptables.

## Architecture

```
                       Internet
                          │ ports 80 / 443
 dmz                ┌─────▼─────┐
 172.30.1.0/24      │   proxy   │  nginx: HTTP → HTTPS, TLS
                    └─────┬─────┘
                          │ :5000
                    ┌─────▼─────┐
                    │    api    │  Flask + gunicorn (on dmz and internal)
                    └──┬─────┬──┘
 internal              │     │
 172.30.2.0/24      ┌──▼─┐ ┌─▼─────┐
 (no internet)      │ db │ │ redis │
                    └── ─┘ └──▲────┘
                              │
                    ┌── ──────┴──┐
                    │   worker   │  Redis clicks → Postgres, CSV reports
                    └────────────┘
 admin
 172.30.3.0/24      backup job (one-off pg_dump) ──► db   (db is also on admin)
 (no internet)
```

| Container | Image | Network(s) | Purpose |
|---|---|---|---|
| `proxy` | `nginxinc/nginx-unprivileged:1.27-alpine` | dmz | Redirects HTTP to HTTPS and forwards requests to the API |
| `api` | built from [`api/`](api/) | dmz, internal | Creates short links, redirects, serves click stats |
| `db` | `postgres:16-alpine` | internal, admin | Stores links and clicks (volume `pgdata`) |
| `redis` | `redis:7.4-alpine` | internal | Link cache and click queue (volume `redisdata`) |
| `worker` | built from [`worker/`](worker/) | internal | Moves clicks from Redis to Postgres, writes CSV reports (volume `reports`) |
| backup job | `postgres:16-alpine` | admin | Throwaway `pg_dump` container started by `scripts/backup.sh` |

Every long-running container runs with all capabilities dropped (except `CHOWN`,
`SETUID`, `SETGID`), `no-new-privileges`, a read-only filesystem, 256 MB memory,
0.5 CPU, rotated logs and `--restart unless-stopped`.

## Prerequisites

You need all of the following on the machine that runs the containers.

**Host**
- [ ] A Linux host (VM or bare metal, e.g. Ubuntu 22.04+ / Debian 12). The
      firewall uses `iptables`, `modprobe br_netfilter` and `sysctl`, so it won't
      run on Docker Desktop for Windows or macOS.
- [ ] Root access (`sudo`). `up.sh` refuses to run otherwise.
- [ ] Ports **80** and **443** free on the host.
- [ ] Internet access to pull images and clone the repo.
- [ ] Roughly 1.5 GB RAM free (5 containers × 256 MB limit) and a few GB of disk.

**Software**
- [ ] `bash` 4+ and `git`
- [ ] Docker Engine 20.10+ (`up.sh` installs `docker.io` with `apt-get` if
      Docker is missing)
- [ ] `iptables` with the `conntrack` match, and the `br_netfilter` kernel module
- [ ] `openssl` (to generate the TLS certificate)
- [ ] `curl` (optional, for trying the API)

**Files the scripts expect**
- [ ] `/secrets/DB_PASSWORD` and `/secrets/POSTGRES_PASSWORD`, both holding the
      **same** password (the API, worker and backup log in as the `linkly` user
      that Postgres creates with `POSTGRES_PASSWORD`)
- [ ] `proxy/certs/tls.crt` and `proxy/certs/tls.key` (git-ignored, so generate them)
- [ ] The API and worker images, available locally or on Docker Hub (see step 3)

## Getting started

### 1. Clone the repository

`up.sh` uses the clone it lives in, so you can run it from any folder. The
examples below run the scripts from the parent folder of the clone:

```bash
mkdir -p ~/linkly && cd ~/linkly
git clone https://github.com/amittkjain05/Docker-Project.git
```

### 2. Create the secrets

```bash
sudo mkdir -p /secrets
PASS="$(openssl rand -hex 24)"
echo "$PASS" | sudo tee /secrets/DB_PASSWORD /secrets/POSTGRES_PASSWORD >/dev/null
sudo chmod 755 /secrets
sudo chmod 644 /secrets/DB_PASSWORD /secrets/POSTGRES_PASSWORD
```

The files must be readable inside the containers, which run as non-root users
(the API and worker as UID 10001), hence mode `644`. `up.sh` checks these
permissions and that both files hold the same password before starting
anything. Keep the host itself restricted to trusted users.

### 3. Build the application images

`up.sh` starts `${IMAGE_REPO}:api_app-${APP_TAG}` and `${IMAGE_REPO}:worker-${APP_TAG}`.
Both are set at the top of [`scripts/up.sh`](scripts/up.sh):
`IMAGE_REPO="amitjain6/linkly_app"` and `APP_TAG="67f6b8d"`, whose images are
already on Docker Hub, so you can skip this step.

To run your own build, build and tag both images, then set `APP_TAG` to your tag:

```bash
cd ~/linkly/Docker-Project
docker build -t amitjain6/linkly_app:api_app-mytag api/
docker build -t amitjain6/linkly_app:worker-mytag worker/
```

To share them, push to Docker Hub with `docker push`.

### 4. Generate the TLS certificate

```bash
bash ~/linkly/Docker-Project/proxy/gen-cert.sh
```

This creates a self-signed certificate for `localhost` in `proxy/certs/`, valid
for 365 days. Replace it with a real certificate for a public host.

### 5. Start everything

```bash
cd ~/linkly
sudo bash Docker-Project/scripts/up.sh
```

The script:
1. Checks the secrets, the proxy config and the certificates.
2. Creates the `dmz`, `internal` (no internet) and `admin` (no internet) networks
   and the `pgdata`, `redisdata` and `reports` volumes.
3. Starts `db → redis → api → worker → proxy` with fixed IPs, waiting for each to
   be healthy before the next.
4. Applies the firewall rules in the `DOCKER-USER` iptables chain.

It's safe to re-run: containers that are already healthy are skipped.

### 6. Check the network policy (optional)

```bash
sudo bash Docker-Project/scripts/netcheck.sh
```

It probes each source → target pair from inside the containers' network
namespaces and prints PASS/FAIL per row. It exits non-zero if any row differs
from the expected result.

## Using the API

All requests go through the proxy over HTTPS. Use `-k` with the self-signed
certificate.

```bash
# Create a short link
curl -k -X POST https://localhost/links \
     -H 'Content-Type: application/json' \
     -d '{"url": "https://example.com"}'
# → {"code": "aB3xYz", "url": "https://example.com"}

# Follow it (302 redirect; the click is queued in Redis)
curl -k -I https://localhost/aB3xYz

# Click count (updated once the worker has moved the click to Postgres)
curl -k https://localhost/stats/aB3xYz

# Health of the API and its dependencies
curl -k https://localhost/health
```

| Method | Path | Description |
|---|---|---|
| `POST` | `/links` | Body `{"url": "http(s)://..."}`. Returns a 6-character code (`201`) |
| `GET` | `/<code>` | Redirects to the stored URL (`302`), or `404` |
| `GET` | `/stats/<code>` | `{"code": ..., "clicks": N}` |
| `GET` | `/health` | `200` if Postgres and Redis respond, else `503` |
| `GET` | `/slow?seconds=N` | Test endpoint that sleeps up to 30 s |

Plain HTTP on port 80 redirects to HTTPS. `http://<host>/healthz` is the
proxy's own health check.

## Reports

The worker writes `clicks-YYYY-MM-DD.csv` (code, click count) every
`REPORT_INTERVAL` seconds (default 86400) to the `reports` volume. If
`WEBHOOK_URL` is set, it also posts a summary there. `up.sh` leaves it empty
because the worker has no internet access.

## Backups

```bash
sudo bash Docker-Project/scripts/backup.sh
```

This starts a throwaway `postgres:16-alpine` container on the `admin` network
only, runs `pg_dump` against `db` and writes
`backups/linkly-<UTC timestamp>.sql.gz` at the repo root. The container is
removed when it finishes. Set `SECRETS_DIR` if your secrets aren't in `/secrets`.

To restore a dump into the running database:

```bash
gunzip -c Docker-Project/backups/linkly-20261101T120000Z.sql.gz \
  | sudo docker exec -i db psql -U linkly -d linkly
```

To take backups on a schedule, add a root cron job, for example daily at 02:00:

```
0 2 * * * cd /root/linkly && bash Docker-Project/scripts/backup.sh >> /var/log/linkly-backup.log 2>&1
```

## Stopping

```bash
sudo bash Docker-Project/scripts/down.sh
```

This removes the containers and networks. The `pgdata`, `redisdata` and
`reports` volumes are kept. To delete the data too:

```bash
sudo docker volume rm pgdata redisdata reports
```

The iptables rules stay in the `DOCKER-USER` chain until the next `up.sh` run
or a reboot. To clear them by hand:

```bash
sudo iptables -F DOCKER-USER && sudo iptables -A DOCKER-USER -j RETURN
```

## Repository layout

```
api/                 Flask API, Dockerfile, healthcheck
worker/              Click worker, Dockerfile, healthcheck
proxy/               nginx config, gen-cert.sh, Dockerfile (not used by up.sh)
scripts/up.sh        Create networks/volumes, start containers, apply firewall
scripts/down.sh      Remove containers and networks (keeps volumes)
scripts/backup.sh    One-off pg_dump to ./backups
scripts/netcheck.sh  Test the reachability matrix
scripts/iptable_rules.sh  Re-apply only the firewall rules
docs/incidents/      Incident notes
```

## Known issues

These are open problems in the current scripts:

- **Container name `cache`:** `netcheck.sh` refers to `cache`, but the Redis
  container is called `redis`, so `netcheck.sh` stops early.
- **netcheck expectations:** some rows (worker → api, redis/db → api, etc.)
  expect traffic that the firewall blocks, so they report FAIL.
- **Worker crash loop on webhook errors:** see
  [`docs/incidents/incident1`](docs/incidents/incident1).
