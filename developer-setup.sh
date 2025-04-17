#!/bin/bash
set -e
# Prompt for GitHub username

echo -e "\n\nEverything is now getting setup. This process will take a few minutes...\n\n"

# Create user vscode
sudo adduser --disabled-password --uid 1337 --gecos "" vscode

# Create .ssh directory for vscode
sudo mkdir -p /home/vscode/.ssh
sudo chmod 700 /home/vscode/.ssh

sudo touch /home/vscode/.ssh/authorized_keys 
sudo chmod 600 /home/vscode/.ssh/authorized_keys
sudo chown -R vscode:vscode /home/vscode/.ssh

# Give vscode sudo access without a password
echo "vscode ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/vscode > /dev/null

echo "Installing other requirements now"

curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh && sudo apt-get update && sudo apt install tmux jq figlet -y && sudo apt-get clean
#export DEBIAN_FRONTEND=noninteractive
#sudo apt-get -s dist-upgrade | grep "^Inst" | grep -i securi | awk -F " " {'print $2'} | xargs sudo apt-get install -y
sudo groupadd -f docker
sudo usermod -aG docker vscode
echo 'fs.inotify.max_user_instances=1024' | sudo tee -a /etc/sysctl.conf
echo 1024 | sudo tee /proc/sys/fs/inotify/max_user_instances
echo "Create .glueopsrc"


dev() {
    if command -v tmux &> /dev/null && [ -z "$TMUX" ]; then
        if tmux attach-session -t dev 2>/dev/null; then
            # Successfully attached to existing session, do nothing more
            :
        else
            # Creating a new tmux session and running a command
            tmux new-session -s dev -d
            tmux send-keys -t dev "dev" C-m
            tmux attach-session -t dev
        fi
    fi
    echo "Fetching the last 5 tags..."
    if [ "${ENVIRONMENT:-prod}" = "nonprod" ]; then
        echo "WARNING: RUNNING IN NONPROD ENVIRONMENT"
        IFS=$'\n' tags=($(curl -s https://api-provisioner.glueopshosted.rocks/v1/get-images | jq -r '.images[]' | head -5))
    else
        IFS=$'\n' tags=($(curl -s https://api-provisioner.glueopshosted.com/v1/get-images | jq -r '.images[]' | head -5))
    fi

    # Check for cached images
    cached_images=$(sudo docker images --format "{{.Repository}}:{{.Tag}}" | grep "ghcr.io/glueops/codespaces")

    # Add a custom option and check if each tag is cached
    tags+=("Custom")
    for i in "${!tags[@]}"; do
        if echo "$cached_images" | grep -q "${tags[$i]}"; then
            tags[$i]="${tags[$i]} (cached)"
        fi
    done

    PS3="Please select a tag (or 'Custom' to enter one): "
    select tag in "${tags[@]}"; do
        # Remove the (cached) part from the tag if present
        selected_tag="${tag/(cached)/}"
        selected_tag="${selected_tag// /}"

        if [[ -z "$selected_tag" ]]; then
            echo "Invalid selection. Please try again."
        elif [ "$selected_tag" == "Custom" ]; then
            read -p "Enter custom tag: " customTag
            export CONTAINER_TAG_TO_USE=$customTag
            echo "CONTAINER_TAG_TO_USE set to $customTag"
            break
        else
            export CONTAINER_TAG_TO_USE=$selected_tag
            echo "CONTAINER_TAG_TO_USE set to $selected_tag"
            break
        fi
    done

    mkdir -p /workspaces/glueops

    CONTAINER_NAME="codespace"
    YELLOW="\033[1;33m"  # Bright Yellow
    ORANGE="\033[0;33m"  # Dim Yellow (Orange-ish)
    RED="\033[1;31m"     # Red
    NC="\033[0m"         # No Color / Reset
    
    # Check if the container exists
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        # If the container exists, check if it's running
        STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")
    
        # Get the image name and tag from the container
        IMAGE_NAME_TAG=$(sudo docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")
        CONTAINER_TAG_TO_USE="$IMAGE_NAME_TAG"
    
        # Output the image tag
        echo -e "${YELLOW}📦 Using image tag: ${CONTAINER_TAG_TO_USE}${NC}"
    
        if [ "$STATUS" = "running" ]; then
            echo -e "${RED}❗ Container '$CONTAINER_NAME' is already running. Using the existing image tag: '$IMAGE_NAME_TAG' (ignoring any provided tag).${NC}"
        else
            echo -e "${ORANGE}🟠 Container '$CONTAINER_NAME' is stopped.${NC}"
            echo -e "${YELLOW}Starting container '$CONTAINER_NAME' now...${NC}"
            sudo docker start "$CONTAINER_NAME"
        fi
    else
        echo -e "${YELLOW}❌ Container '$CONTAINER_NAME' does not exist.${NC}"
        echo -e "${YELLOW}🧼 Creating a new container...${NC}"
        sleep 3;
    
        # Start a new container
        sudo docker run -itd --name "$CONTAINER_NAME" \
            --net=host \
            --cap-add=SYS_PTRACE \
            --security-opt seccomp=unconfined \
            --privileged \
            --init \
            --device=/dev/net/tun \
            -u "$(id -u):$(getent group docker | cut -d: -f3)" \
            -v /workspaces/glueops:/workspaces/glueops \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock \
            -w /workspaces/glueops \
            ghcr.io/glueops/codespaces:${CONTAINER_TAG_TO_USE} bash
    fi

    LOG_OPTIONS="--log off"
    if [ "$CODESPACE_ENABLE_VERBOSE_LOGS" = "true" ]; then
      LOG_OPTIONS="--verbose --log trace"
    fi
    
    # Exec into the container and run the code tunnel (shell stays open)
    sudo docker exec -it "$CONTAINER_NAME" bash -c "code tunnel --random-name $LOG_OPTIONS"
}

GLUEOPSRC="$(declare -f dev)"
echo "$GLUEOPSRC" | sudo tee -a /home/vscode/.glueopsrc



dev() {
    if [ "$(whoami)" != "vscode" ]; then
        echo -e "\033[1;31m⚠️  You are not the 'vscode' user. Switching to 'vscode' and running 'dev' \033[0m"
        exec su - vscode -c "bash -i -c dev"
    else
        echo "You are already the 'vscode' user."
    fi
}

ROOTBASHRC="$(declare -f dev)"
echo "$ROOTBASHRC" | sudo tee -a /root/.bashrc



echo "source /home/vscode/.glueopsrc" | sudo tee -a /home/vscode/.bashrc
sudo chown -R vscode:vscode /home/vscode
sudo mkdir -p /workspaces
sudo chown -R vscode:vscode /workspaces
# disables the password for the current user (ex. root/admin/ubuntu users)
sudo passwd -d $USER
server_ip=$(echo $SSH_CONNECTION | awk '{print $3}')
echo ""
echo ""
#sudo figlet GlueOps | sudo tee /etc/motd
{ echo -e "\e[1;32m$(figlet GlueOps)\e[0m"; echo ""; echo -e "\e[1;34mPlease log in as user 'vscode' or switch to that user by running:\e[0m"; echo ""; echo -e "\e[1;33m    sudo su - vscode\e[0m"; echo ""; echo -e "\e[1;34mAfter switching to the 'vscode' user, run the following command:\e[0m"; echo ""; echo -e "\e[1;33m    dev\e[0m"; } | sudo tee /etc/motd

#Install tailscale
curl -fsSL https://tailscale.com/install.sh | sh



if [ -z "$GLUEOPS_CODESPACES_CONTAINER_TAG" ]; then
  echo "GLUEOPS_CODESPACES_CONTAINER_TAG is not set."
else
  # If the variable is set, pull the Docker image using the tag
  echo "Pulling down codespace version: $GLUEOPS_CODESPACES_CONTAINER_TAG"
  sudo docker pull ghcr.io/glueops/codespaces:$GLUEOPS_CODESPACES_CONTAINER_TAG
fi

echo -e "\n\n\n\n\nPlease reboot using: sudo reboot \n\n"


