#check if git is installed and if not install it and clone the repo
if ! command -v git &> /dev/null ; then
    echo "git could not be found, installing git..."
    apt-get update && apt-get install -y git
fi

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

#validate if docker is running and if not start it
if ! systemctl is-active --quiet docker ; then
    echo "docker is not running, starting docker..."
    systemctl start docker
    systemctl enable docker
fi

#pre-requisites to run the project
#1. Create 3 networks named dmz, internal and admin
# check if the networks already exist, if not create them
if ! docker network ls | grep -q dmz ; then
    docker network create --driver bridge --subnet 172.30.1.0/24 dmz
fi
if ! docker network ls | grep -q internal ; then
    docker network create --driver bridge --internal --subnet 172.30.2.0/24 internal
fi
if ! docker network ls | grep -q admin ; then
    docker network create --driver bridge --internal --subnet 172.30.3.0/24 admin
fi

#2. Create 3 volumes named reports, redisdata and pgdata
# check if the volumes already exist, if not create them
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
docker run -d --name db \
--network internal \ 
--cap-drop ALL \
--mount type=volume,source=pgdata,target=/var/lib/postgresql/data \
--mount type=bind,source=/secrets,target=/run/secrets,ro \
-e POSTGRES_USER=linkly \
-e POSTGRES_PASSWORD_FILE=/run/secrets/POSTGRES_PASSWORD \
-e POSTGRES_DB=linkly \
postgres:16-alpine

docker network connect admin db
#how to make db service to talk only with API service and backup service and not any other service.

#validate if the database service is up and running, if it is not running then wait for some time and then 
#check again, if it is still not running then exit the script with an error message

if ! docker ps --filter "name=db" --filter "status=running" | grep -q db ; then
    echo "Database service failed to start. Please check the logs for more details."
    exit 1
fi

#2. Start the redis service
docker run -d --name redis \
--network internal \
--cap-drop ALL \
--mount type=volume,source=redisdata,target=/data \
redis:7.4-alpine \
redis-server --appendonly yes --appendfsync everysec


#validate if the redis service is up and running
if ! docker ps --filter "name=redis" --filter "status=running" | grep -q redis ; then
    echo "Redis service failed to start. Please check the logs for more details."
    exit 1
fi

#3. Start the api service
# Images need to be tagged with the SHA
docker run -d --name api \
--network dmz \
-e DB_HOST=db \
-e DB_PASSWORD_FILE=/run/secrets/DB_PASSWORD \
-e REDIS_HOST=redis \
--mount type=bind,source=/secrets,target=/run/secrets,ro \
--cap-drop ALL \
amitjain6/linkly_app:api_app-2.0  

docker network connect internal api

#validate if the api service is up and running
if ! docker ps --filter "name=api" --filter "status=running" | grep -q api ; then
    echo "API service failed to start. Please check the logs for more details."
    exit 1
fi


#4. Start the worker service, 
## Changes required : we need to power up the app service before the worker service, as the worker service depends on the app service to be up and running.
docker run -d --name worker \
--network internal \
-e REDIS_HOST=redis \
-e DB_HOST=db \
-e DB_PASSWORD_FILE=/run/secrets/DB_PASSWORD \
--cap-drop ALL \
--mount type=volume,source=reports,target=/app/reports \
--mount type=bind,source=/secrets,target=/run/secrets,ro \
amitjain6/linkly_app:worker-1.0


#validate if the worker service is up and running
if ! docker ps --filter "name=worker" --filter "status=running" | grep -q worker ; then
    echo "Worker service failed to start. Please check the logs for more details."
    exit 1
fi



#5. Start the proxy service
docker run -d --name proxy --network dmz --cap-drop ALL -p 80:8080 -p 443:8443 amitjain6/linkly_app:proxy-2.0


#validate if the proxy service is up and running
if ! docker ps --filter "name=proxy" --filter "status=running" | grep -q proxy ; then
    echo "Proxy service failed to start. Please check the logs for more details."
    exit 1
fi

#6. start the backup service
docker run -d --name backup \
--network internal \
--cap-drop ALL \
--cap-add CHOWN,SETUID,SETGID \
-v pgdata:/var/lib/postgresql \
amitjain6/linkly_app:backup-1.0
#need to fix the command


#validate if the backup service is up and running
if ! docker ps --filter "name=backup" --filter "status=running" | grep -q backup ; then
    echo "Backup service failed to start. Please check the logs for more details."
    exit 1
fi


#configure the IPTABLES to restrict access of the services.
#Run the netcheck script to check the network configuration and output the result.

