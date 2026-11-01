#!/usr/bin/env bash
# Evaluate the Linkly project against a list of criteria and print a PASS/FAIL
# summary. Logs and the summary are saved under logs/evaluate-<timestamp>/.
#
# Usage: sudo scripts/evaluate.sh [--cold] [criterion-id ...]
#   --cold          also delete the data volumes and the cached app images first,
#                   to time a first-ever deployment (this deletes all data)
#   criterion-id    run only these criteria (default: all). See --list.
#   --list          list the criteria and exit
#
# To add a criterion: write a function named criterion_<id> that returns 0 for
# PASS and 1 for FAIL (call `detail "..."` to explain the result), then add a
# line "<id>|<description>" to CRITERIA below.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_DIR/scripts"
RUN_DIR="$REPO_DIR/logs/evaluate-$(date -u +%Y%m%dT%H%M%SZ)"

SERVICES=(db redis api worker proxy)    # long-running containers started by up.sh
UP_TIME_LIMIT=600                       # seconds (10 minutes)
BASE_URL="https://localhost"            # the proxy, as a user would reach it
API_IMAGE_LIMIT_MB=200                  # 1 MB = 1,000,000 bytes, as docker reports sizes
CLICK_WAIT=30                           # seconds to wait for the worker to count a click
SECRETS_DIR="/secrets"                  # same as up.sh
SCAN_CONTAINERS=(api worker)            # images built from this repo, scanned by Trivy
TRIVY_FLAGS=(--severity CRITICAL --ignore-unfixed --exit-code 1)
TRIVY_DOCKER_IMAGE="aquasec/trivy:0.56.2"   # used only when trivy isn't installed
TRIVY_TIMEOUT=900                       # seconds per image (first run downloads the vuln DB)

# id|description, in the order they run
CRITERIA=(
    "up_healthy|up.sh brings all services to healthy in <= 10 min (timed run in a new session)"
    "reachability|All reachability matrix cells match (netcheck.sh exits 0)"
    "dual_homed|Only the api is on both dmz and internal (docker network inspect dmz internal)"
    "published_ports|Only the proxy publishes ports (docker ps --format '{{.Names}} {{.Ports}}')"
    "app_works|Create a link, follow it, stats count the click (curl through the proxy)"
    "api_image_size|api image size <= ${API_IMAGE_LIMIT_MB} MB (docker image inspect -f '{{.Size}}')"
    "process_user|No process runs as root in api and worker (docker top <container> -o user,pid,cmd)"
    "hardening|Every container: CapDrop ALL, ReadonlyRootfs true, memory and CPU limits (docker inspect)"
    "secret_exposure|DB password not in any container's Config.Env (docker inspect)"
    "durability|Same link count after down.sh and up.sh (count before and after)"
    "backup|backup.sh writes a .sql.gz containing your links (zcat the file and grep a code)"
    "vulnerabilities|0 fixable CRITICAL vulns in api and worker images (trivy ${TRIVY_FLAGS[*]})"
)
# Criteria that stop and restart the stack (used for the warning below)
RESTARTS_STACK=(up_healthy durability)

# Short code of a link created during this run; app_works sets it, and
# durability and backup reuse it (or create one when run on their own).
EVAL_CODE=""
EVAL_URL=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()    { echo "[evaluate] $*"; }
die()    { echo "[evaluate] ERROR: $*" >&2; exit 2; }
detail() { DETAILS+=("$*"); echo "           $*"; }

fmt_time() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# "healthy", "running" (no healthcheck), "unhealthy", "starting", "exited", "missing", ...
service_state() {
    local running health status
    read -r status running health < <(docker container inspect -f \
        '{{.State.Status}} {{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        "$1" 2>/dev/null) || { echo missing; return; }
    # A crash-looping container is "restarting" but still has Running=true.
    if [[ "$running" != "true" || "$status" != running ]]; then echo "$status"
    elif [[ -n "${health:-}" ]]; then echo "$health"
    else echo running
    fi
}

# Prefix that runs a script in a new, clean session: a fresh bash with no
# environment, variables or functions inherited from the caller's shell.
NEW_SESSION=(
    env -i
    HOME="${HOME:-/root}"
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    LANG="${LANG:-C.UTF-8}"
    TERM="${TERM:-dumb}"
    bash --noprofile --norc
)

# Run a SQL query in the db container (local socket, no password needed).
db_query() {
    docker exec db psql -U linkly -d linkly -tAc "$1" 2>>"$RUN_DIR/db_query.log"
}

# curl through the proxy; -k because the certificate is self-signed.
api_curl() { curl -sk --max-time 10 "$@"; }

# Create a short link and store its code in EVAL_CODE. Returns 1 on failure.
create_link() {
    local url body code
    url="https://example.com/linkly-eval-$(date +%s)-$RANDOM"
    body=$(api_curl -X POST "$BASE_URL/links" -H 'Content-Type: application/json' \
        -d "{\"url\": \"$url\"}" -w '\n%{http_code}') || return 1
    [[ "${body##*$'\n'}" == 201 ]] || return 1
    code=$(grep -o '"code": *"[A-Za-z0-9]*"' <<<"$body" | sed 's/.*"\([A-Za-z0-9]*\)"$/\1/')
    [[ -n "$code" ]] || return 1
    EVAL_CODE="$code"
    EVAL_URL="$url"
}

# Make sure EVAL_CODE holds a link that exists, creating one if needed.
ensure_link() {
    [[ -n "$EVAL_CODE" ]] && return 0
    command -v curl &>/dev/null || { detail "curl not installed; can't create a test link"; return 1; }
    if create_link; then
        detail "created test link $EVAL_CODE"
    else
        detail "could not create a test link via POST $BASE_URL/links"
        return 1
    fi
}

# Run down.sh in a new session, logging to the given file. On failure, show its
# warnings in the details so the reason is visible without opening the log.
run_down() { # logfile [down.sh args...]
    local logfile="$1" line; shift
    "${NEW_SESSION[@]}" "$SCRIPTS/down.sh" "$@" >"$RUN_DIR/$logfile" 2>&1 && return 0
    detail "down.sh reported problems (see $logfile):"
    while IFS= read -r line; do detail "  $line"; done \
        < <(grep -E 'WARNING|ERROR' "$RUN_DIR/$logfile" | tail -n 5)
    return 1
}

# Run down.sh then up.sh in new sessions; logs go to <prefix>-down.log / -up.log.
restart_stack() {
    local prefix="$1" rc
    run_down "$prefix-down.log" || true
    ( cd "$REPO_DIR" && timeout --foreground "$UP_TIME_LIMIT" \
        "${NEW_SESSION[@]}" "$SCRIPTS/up.sh" ) >"$RUN_DIR/$prefix-up.log" 2>&1
    rc=$?
    (( rc == 0 )) || detail "up.sh failed (exit $rc, see $prefix-up.log)"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Criteria
# ---------------------------------------------------------------------------

# up.sh brings every service to healthy within UP_TIME_LIMIT, starting from a
# clean state (no Linkly containers or networks) in a new shell session.
criterion_up_healthy() {
    local down_args=() rc start elapsed state ok=0

    (( COLD )) && down_args=(--volumes)
    log "resetting to a clean state with down.sh${down_args[*]:+ ${down_args[*]}}"
    run_down down.log "${down_args[@]}" || true
    if (( COLD )); then
        # Remove the app images so up.sh has to pull them, as on a new machine.
        local repo tag
        repo=$(sed -n 's/^IMAGE_REPO="\([^"]*\)".*/\1/p' "$SCRIPTS/up.sh")
        tag=$(sed -n 's/^APP_TAG="\([^"]*\)".*/\1/p' "$SCRIPTS/up.sh")
        if [[ -n "$repo" && -n "$tag" ]]; then
            docker rmi -f "$repo:api_app-$tag" "$repo:worker-$tag" &>/dev/null || true
        fi
    fi

    local leftover=0
    for c in "${SERVICES[@]}"; do
        state=$(service_state "$c")
        if [[ "$state" != missing ]]; then
            detail "'$c' still exists after down.sh (state: $state); remove it with: docker rm -f $c"
            leftover=1
        fi
    done
    (( leftover )) && return 1

    log "running up.sh (limit $(fmt_time "$UP_TIME_LIMIT")); output in up.log"
    start=$(date +%s)
    ( cd "$REPO_DIR" && timeout --foreground "$UP_TIME_LIMIT" \
        "${NEW_SESSION[@]}" "$SCRIPTS/up.sh" ) >"$RUN_DIR/up.log" 2>&1
    rc=$?
    elapsed=$(( $(date +%s) - start ))

    if (( rc == 124 )); then
        detail "up.sh did not finish within $(fmt_time "$UP_TIME_LIMIT")"
        ok=1
    elif (( rc != 0 )); then
        detail "up.sh failed (exit $rc) after $(fmt_time "$elapsed"); last lines:"
        while IFS= read -r line; do detail "  $line"; done < <(tail -n 5 "$RUN_DIR/up.log")
        ok=1
    else
        detail "up.sh finished in $(fmt_time "$elapsed") (limit $(fmt_time "$UP_TIME_LIMIT"))"
    fi

    # Check each service ourselves rather than trusting up.sh's exit code.
    for c in "${SERVICES[@]}"; do
        state=$(service_state "$c")
        if [[ "$state" == healthy ]]; then
            detail "$c: healthy"
        else
            detail "$c: $state"
            ok=1
        fi
    done

    # End to end: the proxy must serve the API's /health over HTTPS.
    if command -v curl &>/dev/null; then
        local code
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://localhost/health || true)
        if [[ "$code" == 200 ]]; then
            detail "https://localhost/health: 200"
        else
            detail "https://localhost/health: ${code:-no response} (expected 200)"
            ok=1
        fi
    else
        detail "curl not installed; skipped the https://localhost/health check"
    fi

    (( elapsed <= UP_TIME_LIMIT )) || ok=1
    return "$ok"
}

# Every cell of the reachability matrix matches: netcheck.sh exits 0.
# Uses the running stack, so run it after up_healthy (or on a stack you started).
criterion_reachability() {
    local rc total passed

    log "running netcheck.sh; output in netcheck.log"
    ( cd "$REPO_DIR" && "${NEW_SESSION[@]}" "$SCRIPTS/netcheck.sh" ) >"$RUN_DIR/netcheck.log" 2>&1
    rc=$?

    total=$(grep -cE ' (PASS|FAIL) \(' "$RUN_DIR/netcheck.log")
    passed=$(grep -cE ' PASS \(' "$RUN_DIR/netcheck.log")

    case "$rc" in
        0)
            detail "netcheck.sh exited 0: $passed/$total cells match"
            return 0 ;;
        1)
            detail "netcheck.sh exited 1: $passed/$total cells match; mismatches:"
            while IFS= read -r line; do detail "  $line"; done \
                < <(grep -E ' FAIL \(' "$RUN_DIR/netcheck.log") ;;
        *)
            # Exit 2 means netcheck couldn't start (a service down, Docker unreachable, ...)
            detail "netcheck.sh could not run (exit $rc):"
            while IFS= read -r line; do detail "  $line"; done < <(tail -n 3 "$RUN_DIR/netcheck.log") ;;
    esac
    return 1
}

# The api is the only container attached to both dmz and internal, so nothing
# else can bridge the public-facing network and the data network.
criterion_dual_homed() {
    local net members both=() c
    local -A on_dmz=()

    # Keep the full inspect output as evidence.
    if ! docker network inspect dmz internal >"$RUN_DIR/network-inspect.json" 2>&1; then
        detail "docker network inspect dmz internal failed (is the stack up?):"
        while IFS= read -r line; do detail "  $line"; done < <(tail -n 3 "$RUN_DIR/network-inspect.json")
        return 1
    fi

    for net in dmz internal; do
        members=$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net")
        members=$(tr ' ' '\n' <<<"$members" | sed '/^$/d' | sort | tr '\n' ' ')
        detail "$net: ${members:-(no containers)}"
        for c in $members; do
            if [[ "$net" == dmz ]]; then
                on_dmz[$c]=1
            elif [[ -n "${on_dmz[$c]:-}" ]]; then
                both+=("$c")
            fi
        done
    done

    if [[ "${both[*]:-}" == "api" ]]; then
        detail "on both: api (only)"
        return 0
    fi
    detail "on both: ${both[*]:-(none)} (expected: api only)"
    return 1
}

# The proxy is the only container with ports published on the host. Docker
# shows a published port as "0.0.0.0:443->8443/tcp"; a port that is only
# exposed inside the network shows as "5000/tcp" and doesn't count.
criterion_published_ports() {
    local name ports publishers=() proxy_ports=""

    # Keep the raw output as evidence.
    if ! docker ps --format '{{.Names}} {{.Ports}}' >"$RUN_DIR/docker-ps.txt" 2>&1; then
        detail "docker ps failed:"
        while IFS= read -r line; do detail "  $line"; done < <(tail -n 3 "$RUN_DIR/docker-ps.txt")
        return 1
    fi

    while read -r name ports; do
        [[ -n "$name" ]] || continue
        if [[ "$ports" == *"->"* ]]; then
            publishers+=("$name")
            detail "$name: $ports"
            [[ "$name" == proxy ]] && proxy_ports="$ports"
        else
            detail "$name: ${ports:-(no ports)} (not published)"
        fi
    done <"$RUN_DIR/docker-ps.txt"

    if [[ -z "$proxy_ports" ]]; then
        detail "proxy publishes no ports (is it running?)"
        return 1
    fi
    if [[ "${publishers[*]}" != "proxy" ]]; then
        detail "publishing ports: ${publishers[*]} (expected: proxy only)"
        return 1
    fi
    detail "publishing ports: proxy (only)"
    return 0
}

# End to end through the proxy, like the curl examples in the README:
# create a link, follow it, and see the worker count the click.
criterion_app_works() {
    local status location clicks="" waited=0

    command -v curl &>/dev/null || { detail "curl not installed"; return 1; }

    if ! create_link; then
        detail "POST $BASE_URL/links did not return 201 with a code"
        return 1
    fi
    detail "POST /links -> 201, code $EVAL_CODE for $EVAL_URL"

    read -r status location < <(api_curl -o /dev/null -w '%{http_code} %{redirect_url}\n' "$BASE_URL/$EVAL_CODE")
    if [[ "${status:-}" != 302 || "${location:-}" != "$EVAL_URL" ]]; then
        detail "GET /$EVAL_CODE -> ${status:-no response} ${location:-} (expected 302 to $EVAL_URL)"
        return 1
    fi
    detail "GET /$EVAL_CODE -> 302 to $location"

    # The click goes to Redis first; the worker moves it to Postgres shortly after.
    while (( waited <= CLICK_WAIT )); do
        clicks=$(api_curl "$BASE_URL/stats/$EVAL_CODE" | grep -o '"clicks": *[0-9]*' | grep -o '[0-9]*$')
        (( ${clicks:-0} >= 1 )) && break
        sleep 2; (( waited += 2 ))
    done
    if (( ${clicks:-0} >= 1 )); then
        detail "GET /stats/$EVAL_CODE -> clicks=$clicks (after ${waited}s)"
        return 0
    fi
    detail "GET /stats/$EVAL_CODE -> clicks=${clicks:-?} after ${CLICK_WAIT}s (expected >= 1; is the worker running?)"
    return 1
}

# The image the api container runs is at most API_IMAGE_LIMIT_MB.
criterion_api_image_size() {
    local image name size limit
    limit=$(( API_IMAGE_LIMIT_MB * 1000 * 1000 ))

    image=$(docker inspect -f '{{.Image}}' api 2>/dev/null)
    name=$(docker inspect -f '{{.Config.Image}}' api 2>/dev/null)
    if [[ -z "$image" ]]; then
        # api isn't running: fall back to the image up.sh would start.
        local repo tag
        repo=$(sed -n 's/^IMAGE_REPO="\([^"]*\)".*/\1/p' "$SCRIPTS/up.sh")
        tag=$(sed -n 's/^APP_TAG="\([^"]*\)".*/\1/p' "$SCRIPTS/up.sh")
        image="$repo:api_app-$tag"; name="$image"
    fi

    if ! size=$(docker image inspect -f '{{.Size}}' "$image" 2>/dev/null) || [[ ! "$size" =~ ^[0-9]+$ ]]; then
        detail "could not inspect image $name (not pulled?)"
        return 1
    fi
    detail "$name: $(awk -v s="$size" 'BEGIN{printf "%.1f MB (%.1f MiB)", s/1e6, s/1048576}') (limit ${API_IMAGE_LIMIT_MB} MB)"
    (( size <= limit ))
}

# Neither the api nor the worker runs any process as root.
criterion_process_user() {
    local c out user pid cmd ok=0

    for c in api worker; do
        if ! out=$(docker top "$c" -o user,pid,cmd 2>&1); then
            detail "$c: docker top failed: $out"
            ok=1; continue
        fi
        echo "$out" >"$RUN_DIR/top-$c.txt"
        while read -r user pid cmd; do
            [[ -z "$user" || "$user" == USER ]] && continue
            if [[ "$user" == root || "$user" == 0 ]]; then
                detail "$c: pid $pid runs as root: $cmd"
                ok=1
            else
                detail "$c: pid $pid runs as $user: $cmd"
            fi
        done <<<"$out"
    done
    return "$ok"
}

# Every service: all capabilities dropped, read-only root filesystem, and
# memory and CPU limits.
criterion_hardening() {
    local c capdrop ro mem nano quota problems msg ok=0

    docker inspect "${SERVICES[@]}" >"$RUN_DIR/hardening-inspect.json" 2>&1
    for c in "${SERVICES[@]}"; do
        if ! IFS='|' read -r capdrop ro mem nano quota < <(docker inspect -f \
            '{{join .HostConfig.CapDrop ","}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}' \
            "$c" 2>/dev/null); then
            detail "$c: not found"
            ok=1; continue
        fi
        problems=()
        [[ ",${capdrop^^}," == *",ALL,"* ]] || problems+=("CapDrop is [${capdrop:-none}], not ALL")
        [[ "$ro" == true ]]                 || problems+=("ReadonlyRootfs is $ro")
        (( ${mem:-0} > 0 ))                 || problems+=("no memory limit")
        (( ${nano:-0} > 0 || ${quota:-0} > 0 )) || problems+=("no CPU limit")
        if (( ${#problems[@]} )); then
            msg=$(printf '%s; ' "${problems[@]}")
            detail "$c: ${msg%; }"
            ok=1
        else
            detail "$c: CapDrop ALL, read-only, memory $(( mem / 1024 / 1024 ))m, cpus $(awk -v n="${nano:-0}" -v q="${quota:-0}" 'BEGIN{printf "%g", (n > 0 ? n / 1e9 : q / 1e5)}')"
        fi
    done
    return "$ok"
}

# The database password never appears in a container's environment, and no
# *PASSWORD variable holds a value (passwords come from /run/secrets files).
# The password itself is never printed; saved env dumps have it masked.
criterion_secret_exposure() {
    local f c env name pw passwords=() ok=0 leaked

    for f in DB_PASSWORD POSTGRES_PASSWORD; do
        [[ -r "$SECRETS_DIR/$f" ]] || continue
        pw=$(<"$SECRETS_DIR/$f"); pw="${pw%$'\n'}"
        [[ -n "$pw" ]] && passwords+=("$pw")
    done
    if (( ${#passwords[@]} == 0 )); then
        detail "can't read a password from $SECRETS_DIR to compare against"
        return 1
    fi

    for c in "${SERVICES[@]}"; do
        if ! env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null); then
            detail "$c: not found"
            ok=1; continue
        fi
        leaked=0
        for pw in "${passwords[@]}"; do
            [[ "$env" == *"$pw"* ]] && leaked=1
            env="${env//"$pw"/********}"
        done
        echo "$env" >"$RUN_DIR/env-$c.txt"
        if (( leaked )); then
            detail "$c: the password appears in Config.Env"
            ok=1
        fi
        while IFS= read -r name; do
            detail "$c: $name has a value in Config.Env"
            ok=1
        done < <(grep -oE '^[A-Za-z_]*PASSWORD=.+' <<<"$env" | cut -d= -f1)
        (( leaked )) || grep -qE '^[A-Za-z_]*PASSWORD=.+' <<<"$env" || detail "$c: no password in Config.Env"
    done
    return "$ok"
}

# Links survive a full down.sh + up.sh (the pgdata volume keeps them).
criterion_durability() {
    local before after kept

    ensure_link || return 1
    before=$(db_query 'SELECT count(*) FROM links')
    [[ "$before" =~ ^[0-9]+$ ]] || { detail "could not count links before (is db up?)"; return 1; }
    detail "links before: $before"

    log "restarting the stack with down.sh and up.sh"
    restart_stack durability || return 1

    after=$(db_query 'SELECT count(*) FROM links')
    [[ "$after" =~ ^[0-9]+$ ]] || { detail "could not count links after the restart"; return 1; }
    kept=$(db_query "SELECT count(*) FROM links WHERE code = '$EVAL_CODE'")
    detail "links after: $after; test link $EVAL_CODE still there: $([[ "$kept" == 1 ]] && echo yes || echo no)"
    [[ "$before" == "$after" && "$kept" == 1 ]]
}

# backup.sh writes a new, valid .sql.gz that contains the links table rows.
criterion_backup() {
    local marker file rc tab
    tab=$'\t'

    ensure_link || return 1
    marker="$RUN_DIR/.backup-start"
    touch "$marker"

    log "running backup.sh; output in backup.log"
    ( cd "$REPO_DIR" && "${NEW_SESSION[@]}" "$SCRIPTS/backup.sh" ) >"$RUN_DIR/backup.log" 2>&1
    rc=$?
    if (( rc != 0 )); then
        detail "backup.sh failed (exit $rc); last lines:"
        while IFS= read -r line; do detail "  $line"; done < <(tail -n 3 "$RUN_DIR/backup.log")
        return 1
    fi

    file=$(find "$REPO_DIR/backups" -maxdepth 1 -name '*.sql.gz' -newer "$marker" 2>/dev/null | sort | tail -n 1)
    if [[ -z "$file" ]]; then
        detail "backup.sh succeeded but no new .sql.gz in $REPO_DIR/backups"
        return 1
    fi
    detail "new backup: ${file#"$REPO_DIR"/} ($(du -h "$file" | cut -f1))"

    if ! gzip -t "$file" 2>/dev/null; then
        detail "the file is not a valid gzip archive"
        return 1
    fi
    # pg_dump writes table rows as tab-separated lines, so match the code as a row's first field.
    if zcat "$file" | grep -q "^${EVAL_CODE}${tab}"; then
        detail "zcat | grep: found link $EVAL_CODE in the dump"
        return 0
    fi
    detail "zcat | grep: link $EVAL_CODE not found in the dump"
    return 1
}

# Image a container runs, or the image up.sh would start for it when it isn't running.
image_of() { # container tag-prefix
    local image repo tag
    image=$(docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null)
    if [[ -z "$image" ]]; then
        repo=$(sed -n 's/^IMAGE_REPO="\([^"]*\)".*/\1/p' "$SCRIPTS/up.sh")
        tag=$(sed -n 's/^APP_TAG="\([^"]*\)".*/\1/p' "$SCRIPTS/up.sh")
        image="$repo:$2-$tag"
    fi
    echo "$image"
}

# Trivy finds no CRITICAL vulnerability that has a fix available in the
# project's images: `trivy image --severity CRITICAL --ignore-unfixed --exit-code 1`
# exits 0 for each. Uses an installed trivy, or the official Trivy image.
criterion_vulnerabilities() {
    local trivy=() c prefix image report rc ok=0 count ids list

    if command -v trivy &>/dev/null; then
        trivy=(trivy)
        detail "using installed trivy ($(trivy --version 2>/dev/null | head -n 1))"
    else
        # Trivy reads local images through the Docker socket; the cache volume
        # keeps the vulnerability database between runs.
        trivy=(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock
               -v trivy-cache:/root/.cache "$TRIVY_DOCKER_IMAGE")
        detail "trivy not installed; using $TRIVY_DOCKER_IMAGE"
    fi

    for c in "${SCAN_CONTAINERS[@]}"; do
        case "$c" in api) prefix=api_app ;; *) prefix="$c" ;; esac
        image=$(image_of "$c" "$prefix")
        report="$RUN_DIR/trivy-$c.txt"
        log "scanning $image with trivy; output in ${report##*/}"

        timeout "$TRIVY_TIMEOUT" "${trivy[@]}" image "${TRIVY_FLAGS[@]}" --no-progress "$image" >"$report" 2>&1
        rc=$?

        # Trivy also exits 1 on errors, so tell findings apart by the report's "Total:" line.
        if (( rc == 0 )); then
            detail "$c ($image): 0 fixable CRITICAL"
        elif (( rc == 1 )) && grep -q 'CRITICAL: [1-9]' "$report"; then
            # Sum "CRITICAL: N" over every target in the report (OS packages, Python packages, ...).
            count=$(grep -oE 'CRITICAL: [0-9]+' "$report" | awk '{s += $2} END {print s + 0}')
            ids=$(grep -oE '(CVE-[0-9]{4}-[0-9]+|GHSA(-[a-z0-9]{4}){3})' "$report" | sort -u)
            list=$(head -n 5 <<<"$ids" | paste -sd ' ')
            (( $(grep -c . <<<"$ids") > 5 )) && list+=" ..."
            detail "$c ($image): $count fixable CRITICAL: ${list:-see ${report##*/}}"
            ok=1
        elif (( rc == 124 )); then
            detail "$c ($image): trivy timed out after $(fmt_time "$TRIVY_TIMEOUT")"
            ok=1
        else
            detail "$c ($image): trivy failed (exit $rc); last lines:"
            while IFS= read -r line; do detail "  $line"; done < <(tail -n 3 "$report")
            ok=1
        fi
    done
    return "$ok"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
COLD=0
selected=()
for arg in "$@"; do
    case "$arg" in
        --cold) COLD=1 ;;
        --list) for c in "${CRITERIA[@]}"; do printf '%-16s %s\n' "${c%%|*}" "${c#*|}"; done; exit 0 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option '$arg' (see --help)" ;;
        *) selected+=("$arg") ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run as root (up.sh and down.sh need it)"
command -v docker &>/dev/null || die "docker not found"
command -v timeout &>/dev/null || die "'timeout' not found (install coreutils)"

to_run=()
for c in "${CRITERIA[@]}"; do
    id="${c%%|*}"
    if (( ${#selected[@]} == 0 )) || [[ " ${selected[*]} " == *" $id "* ]]; then
        to_run+=("$c")
    fi
done
for s in "${selected[@]}"; do
    printf '%s\n' "${CRITERIA[@]}" | grep -q "^$s|" || die "unknown criterion '$s' (see --list)"
done

for c in "${to_run[@]}"; do
    if [[ " ${RESTARTS_STACK[*]} " == *" ${c%%|*} "* ]]; then
        echo "[evaluate] WARNING: this stops and restarts the Linkly stack."
        (( COLD )) && echo "[evaluate] WARNING: --cold deletes the pgdata, redisdata and reports volumes."
        break
    fi
done
mkdir -p "$RUN_DIR"

results=()
failed=0
for c in "${to_run[@]}"; do
    id="${c%%|*}"; desc="${c#*|}"
    DETAILS=()
    echo
    log "[$id] $desc"
    if "criterion_$id"; then res=PASS; else res=FAIL; failed=1; fi
    log "[$id] $res"
    results+=("$res|$id|$desc")
    { echo "[$res] $id: $desc"; printf '    %s\n' "${DETAILS[@]}"; echo; } >>"$RUN_DIR/summary.txt"
done

echo
echo "================ Evaluation summary ================"
for r in "${results[@]}"; do
    IFS='|' read -r res id desc <<<"$r"
    printf '%-5s %-16s %s\n' "$res" "$id" "$desc"
done
echo "===================================================="
echo "Logs and summary: $RUN_DIR"
exit "$failed"
