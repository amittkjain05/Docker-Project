#!/bin/bash
set -e

git clone https://github.com/yourusername/yourrepo.git
#validate if the repo is cloned successfully
if [ ! -d "yourrepo" ]; then
    echo "Failed to clone the repository. Please check your internet connection and try again."
    exit 1
fi

#validate if docker is installed and if not install it
if ! command -v docker &> /dev/null ; then
    echo "docker could not be found, installing docker..."
    apt-get update && apt-get install -y docker.io  
fi

# pre-requisites to run the project
#1. Create 3 networks named dmz, internal and admin, check if the networks already exist, if not create them
if ! docker network ls | grep -q dmz ; then
    docker network create --driver bridge --subnet 172.30.1.0/24 dmz
fi
if ! docker network ls | grep -q internal ; then
    docker network create --driver bridge --internal --subnet 172.30.2.0/24 internal
fi
if ! docker network ls | grep -q admin ; then
    docker network create --driver bridge --internal --subnet 172.30.3.0/24 admin
fi

#2. Create 3 volumes named reports, redisdata and pgdata. check if the volumes already exist, if not create them
if ! docker volume ls | grep -q reports ; then
    docker volume create reports
fi
if ! docker volume ls | grep -q redisdata ; then
    docker volume create redisdata
fi
if ! docker volume ls | grep -q pgdata ; then
    docker volume create pgdata
fi


#Brings up the services in sequence
#1. Start the database service
 > docker run -d --name db --network internal \
--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --read-only \
--tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,size=100m,mode=1777 \
--memory 256m --cpus 0.5 \
--mount type=volume,source=pgdata,target=/var/lib/postgresql/data \
--mount type=bind,source=/secrets,target=/run/secrets,ro \
-e POSTGRES_USER=linkly -e POSTGRES_PASSWORD_FILE=/run/secrets/POSTGRES_PASSWORD -e POSTGRES_DB=linkly postgres:16-alpine

> docker network connect admin db

#2. Start the redis service
> docker run -d --name redis --network internal \
--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --read-only \
--memory 256m --cpus 0.5 \
--mount type=volume,source=redisdata,target=/data redis:7.4-alpine redis-server --appendonly yes --appendfsync everysec

#3. Start the api service
> docker run -d --name api --network internal \
--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --read-only \
--memory 256m --cpus 0.5 \
--mount type=bind,source=/secrets,target=/run/secrets,ro \
amitjain6/linkly_app:api_app-2463f2d
> docker network connect dmz api

#4. Start the worker service, 
## Changes required : we need to power up the app service before the worker service, as the worker service depends on the app service to be up and running.
> docker run -d --name worker --network internal \
--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --read-only \
--tmpfs /tmp:rw,noexec,nosuid,size=100m,mode=1777 \
--memory 256m --cpus 0.5 \
--mount type=volume,source=reports,target=/app/reports \
--mount type=bind,source=/secrets,target=/run/secrets,ro \
 amitjain6/linkly_app:worker-2463f2d 

#5. Start the proxy service
> docker run -d --name proxy --network dmz \
--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --read-only \
--tmpfs /tmp:rw,noexec,nosuid,size=100m,mode=1777 \
--memory 256m --cpus 0.5 \ 
--security-opt no-new-privileges --read-only --tmpfs /tmp -p 80:8080 -p 443:8443 amitjain6/linkly_app:proxy-2463f2d

#6. start the backup service
> docker run -d --name backup --network internal \
--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges --read-only \
--tmpfs /tmp:rw,noexec,nosuid,size=100m,mode=1777 \
--memory 256m --cpus 0.5 \
-v pgdata:/var/lib/postgresql amitjain6/linkly_app:backup-1.0

#Configure the IPTABLES to restrict access of the services.

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
