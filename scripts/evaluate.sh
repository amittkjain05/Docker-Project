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

# id|description, in the order they run
CRITERIA=(
    "up_healthy|up.sh brings all services to healthy in <= 10 min (timed run in a new session)"
    "reachability|All reachability matrix cells match (netcheck.sh exits 0)"
)
# Criteria that stop and restart the stack (used for the warning below)
RESTARTS_STACK=(up_healthy)

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
    read -r status running health < <(docker inspect -f \
        '{{.State.Status}} {{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
        "$1" 2>/dev/null) || { echo missing; return; }
    if [[ "$running" != "true" ]]; then echo "$status"
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

# ---------------------------------------------------------------------------
# Criteria
# ---------------------------------------------------------------------------

# up.sh brings every service to healthy within UP_TIME_LIMIT, starting from a
# clean state (no Linkly containers or networks) in a new shell session.
criterion_up_healthy() {
    local down_args=() rc start elapsed state ok=0

    (( COLD )) && down_args=(--volumes)
    log "resetting to a clean state with down.sh${down_args[*]:+ ${down_args[*]}}"
    "${NEW_SESSION[@]}" "$SCRIPTS/down.sh" "${down_args[@]}" >"$RUN_DIR/down.log" 2>&1 \
        || detail "note: down.sh reported warnings (see down.log)"
    if (( COLD )); then
        # Remove the app images so up.sh has to pull them, as on a new machine.
        local repo tag
        repo=$(sed -n 's/^IMAGE_REPO="\([^"]*\)".*/\1/p' "$SCRIPTS/up.sh")
        tag=$(sed -n 's/^APP_TAG="\([^"]*\)".*/\1/p' "$SCRIPTS/up.sh")
        if [[ -n "$repo" && -n "$tag" ]]; then
            docker rmi -f "$repo:api_app-$tag" "$repo:worker-$tag" &>/dev/null || true
        fi
    fi

    for c in "${SERVICES[@]}"; do
        [[ "$(service_state "$c")" == missing ]] || { detail "'$c' still exists after down.sh"; return 1; }
    done

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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
COLD=0
selected=()
for arg in "$@"; do
    case "$arg" in
        --cold) COLD=1 ;;
        --list) for c in "${CRITERIA[@]}"; do printf '%-14s %s\n' "${c%%|*}" "${c#*|}"; done; exit 0 ;;
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
    printf '%-5s %-14s %s\n' "$res" "$id" "$desc"
done
echo "===================================================="
echo "Logs and summary: $RUN_DIR"
exit "$failed"
