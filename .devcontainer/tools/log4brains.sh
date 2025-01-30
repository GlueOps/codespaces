#!/bin/bash

# Ensure the script is executable: chmod +x script.sh

# Extract user ID and group ID for the docker group
USER_ID=$(id -u)
GROUP_ID=$(getent group docker | cut -d: -f3)

# Run the docker container with passed parameters
docker run --rm -ti -u "$USER_ID:$GROUP_ID" \
    -v "$(pwd)":/workdir \
    -p 4004:4004 \
    thomvaill/log4brains:1.1.0 "$@"

