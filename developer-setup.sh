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
echo "Save .glueopsrc"
#sudo curl https://raw.githubusercontent.com/GlueOps/development-only-utilities/v0.21.0/tools/developer-setup/.glueopsrc --output /home/vscode/.glueopsrc
sudo curl https://raw.githubusercontent.com/GlueOps/development-only-utilities/refs/heads/major-switch-to-a-directory-under-/-instead-of-/home/vscode/tools/developer-setup/.glueopsrc --output /home/vscode/.glueopsrc

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


