#!/bin/bash
set -e

# 1. Ensure bridge traffic passes through iptables
modprobe br_netfilter || true
sysctl -w net.bridge.bridge-nf-call-iptables=1

# 2. Dynamically extract IP addresses using container names and network names
get_ip() {
    local container="$1"
    local network="$2"
    docker inspect -f "{{with index .NetworkSettings.Networks \"$network\"}}{{.IPAddress}}{{end}}" "$container"
}

PROXY_DMZ_IP=$(get_ip proxy dmz)
API_DMZ_IP=$(get_ip api dmz)
API_INT_IP=$(get_ip api internal)
CACHE_INT_IP=$(get_ip redis internal)
DB_INT_IP=$(get_ip db internal)
WORKER_INT_IP=$(get_ip worker internal)
BACKUP_INT_IP=$(get_ip backup internal)

# 3. Dynamically extract subnet CIDRs
DMZ_CIDR=$(docker network inspect dmz -f '{{(index .IPAM.Config 0).Subnet}}')
INT_CIDR=$(docker network inspect internal -f '{{(index .IPAM.Config 0).Subnet}}')

# 4. Flush and initialize the DOCKER-USER chain
iptables -F DOCKER-USER

# 5. Allow established/related sessions (connection tracking)
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# 6. Allow Docker internal DNS lookups (127.0.0.11)
iptables -A DOCKER-USER -p udp --dport 53 -j ACCEPT
iptables -A DOCKER-USER -p tcp --dport 53 -j ACCEPT

# 7. Apply required communication policies:

# Proxy -> API only
iptables -A DOCKER-USER -s "$PROXY_DMZ_IP" -d "$API_DMZ_IP" -m conntrack --ctstate NEW -j ACCEPT

# API -> Cache (Redis)
iptables -A DOCKER-USER -s "$API_INT_IP" -d "$CACHE_INT_IP" -m conntrack --ctstate NEW -j ACCEPT

# API -> DB (Postgres)
iptables -A DOCKER-USER -s "$API_INT_IP" -d "$DB_INT_IP" -m conntrack --ctstate NEW -j ACCEPT

# Worker -> Cache (Redis) only
iptables -A DOCKER-USER -s "$WORKER_INT_IP" -d "$CACHE_INT_IP" -m conntrack --ctstate NEW -j ACCEPT

# Backup -> DB (Postgres) only
iptables -A DOCKER-USER -s "$BACKUP_INT_IP" -d "$DB_INT_IP" -m conntrack --ctstate NEW -j ACCEPT

# 8. Drop all other traffic between and within the managed container networks
iptables -A DOCKER-USER -s "$DMZ_CIDR" -d "$DMZ_CIDR" -j DROP
iptables -A DOCKER-USER -s "$DMZ_CIDR" -d "$INT_CIDR" -j DROP
iptables -A DOCKER-USER -s "$INT_CIDR" -d "$DMZ_CIDR" -j DROP
iptables -A DOCKER-USER -s "$INT_CIDR" -d "$INT_CIDR" -j DROP

# 9. Return all remaining non-internal traffic to the default Docker chain
iptables -A DOCKER-USER -j RETURN
