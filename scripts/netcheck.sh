#!/usr/bin/env bash
set -euo pipefail

readonly PROBE_IMAGE="busybox:1.36"
readonly API_EGRESS_CHAIN="LINKLY_API_EGRESS"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_running() {
    local container="$1"
    local running

    running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null) \
        || fail "container '$container' does not exist"
    [[ "$running" == "true" ]] || fail "container '$container' is not running"
}

require_network() {
    local container="$1"
    local network="$2"
    local networks

    networks=$(docker inspect --format \
        '{{range $name, $settings := .NetworkSettings.Networks}}{{$name}} {{end}}' \
        "$container") || fail "could not inspect container '$container'"

    grep -qw -- "$network" <<<"$networks" \
        || fail "'$container' is not attached to '$network' (attached: ${networks:-none})"
}

for command in docker grep iptables sysctl; do
    command -v "$command" >/dev/null 2>&1 || fail "required command '$command' was not found"
done

docker info >/dev/null 2>&1 || fail "Docker daemon is not available"
iptables -S DOCKER-USER >/dev/null 2>&1 || fail "Docker's DOCKER-USER chain is unavailable"
[[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" == "1" ]] \
    || fail "net.bridge.bridge-nf-call-iptables must be 1"

for network in dmz internal admin; do
    docker network inspect "$network" >/dev/null 2>&1 \
        || fail "Docker network '$network' does not exist"
done

for container in proxy api db redis worker backup; do
    require_running "$container"
done

# The proxy and API share dmz; the API reaches the database and Redis on internal.
require_network proxy dmz
require_network api dmz
require_network api internal
require_network db internal
require_network redis internal
require_network worker internal
require_network backup internal

# Services other than the API must not be attached to the DMZ.
for container in db redis worker backup; do
    networks=$(docker inspect --format \
        '{{range $name, $settings := .NetworkSettings.Networks}}{{$name}} {{end}}' \
        "$container")
    if grep -qw dmz <<<"$networks"; then
        fail "'$container' is exposed to the dmz network"
    fi
done

# The admin network is reserved and must not expose application services.
for container in proxy api db redis worker backup; do
    networks=$(docker inspect --format \
        '{{range $name, $settings := .NetworkSettings.Networks}}{{$name}} {{end}}' \
        "$container")
    if grep -qw admin <<<"$networks"; then
        fail "'$container' is attached to the admin network"
    fi
done

echo "Checking proxy health on dmz..."
docker run --rm --network dmz "$PROBE_IMAGE" \
    wget -q -O /dev/null http://proxy:8080/healthz \
    || fail "proxy health check failed on dmz"

echo "Checking backend connectivity on internal..."
docker run --rm --network internal "$PROBE_IMAGE" sh -c '
    nc -z -w 3 db 5432 &&
    nc -z -w 3 redis 6379
' || fail "could not reach the database or Redis on internal"

api_ips=$(docker inspect --format \
    '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' api) \
    || fail "could not inspect API IP addresses"
db_ip=$(docker inspect --format \
    '{{(index .NetworkSettings.Networks "internal").IPAddress}}' db) \
    || fail "could not inspect database IP address"
redis_ip=$(docker inspect --format \
    '{{(index .NetworkSettings.Networks "internal").IPAddress}}' redis) \
    || fail "could not inspect Redis IP address"
proxy_ip=$(docker inspect --format \
    '{{(index .NetworkSettings.Networks "dmz").IPAddress}}' proxy) \
    || fail "could not inspect proxy IP address"

iptables -C DOCKER-USER -j "$API_EGRESS_CHAIN" >/dev/null 2>&1 \
    || fail "API egress chain is not attached to DOCKER-USER"
iptables -nL "$API_EGRESS_CHAIN" >/dev/null 2>&1 \
    || fail "API egress chain does not exist"
iptables -C "$API_EGRESS_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT \
    >/dev/null 2>&1 || fail "API established-connection rule is missing"

for api_ip in $api_ips; do
    [[ -n "$api_ip" ]] || continue
    iptables -C "$API_EGRESS_CHAIN" -s "$api_ip" -d "$db_ip" \
        -p tcp --dport 5432 -j ACCEPT >/dev/null 2>&1 \
        || fail "API-to-database allow rule is missing for $api_ip"
    iptables -C "$API_EGRESS_CHAIN" -s "$api_ip" -d "$redis_ip" \
        -p tcp --dport 6379 -j ACCEPT >/dev/null 2>&1 \
        || fail "API-to-Redis allow rule is missing for $api_ip"
    iptables -C "$API_EGRESS_CHAIN" -s "$api_ip" -j DROP >/dev/null 2>&1 \
        || fail "API egress drop rule is missing for $api_ip"
done

echo "Checking API egress policy..."
docker run --rm --network container:api "$PROBE_IMAGE" sh -c \
    "nc -z -w 3 '$db_ip' 5432 && nc -z -w 3 '$redis_ip' 6379" \
    || fail "API network namespace cannot reach the database or Redis"
if docker run --rm --network container:api "$PROBE_IMAGE" \
    nc -z -w 3 "$proxy_ip" 8080; then
    fail "API can initiate a connection to the proxy; egress restriction failed"
fi

echo "PASS: expected network membership and service connectivity verified"
