#Cleanup the setup by removing the containers, networks, and volumes created by docker-compose up
#1. Stop and remove the containers, validate if the containers are stopped and removed successfully, if not then exit the script with an error message
docker stop db redis worker api proxy
  
docker rm db redis worker api proxy

#.2. Remove the networks
docker network rm dmz internal admin
