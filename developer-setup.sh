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

curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo apt-get update
sudo apt install tmux jq figlet qemu-guest-agent autossh -y
sudo apt-get clean

#export DEBIAN_FRONTEND=noninteractive
#sudo apt-get -s dist-upgrade | grep "^Inst" | grep -i securi | awk -F " " {'print $2'} | xargs sudo apt-get install -y
sudo groupadd -f docker
sudo usermod -aG docker vscode
echo 'fs.inotify.max_user_instances=1024' | sudo tee -a /etc/sysctl.conf
echo 1024 | sudo tee /proc/sys/fs/inotify/max_user_instances
echo "Create .glueopsrc"


### Install GUM
# --- Hardcoded Download URL ---
DOWNLOAD_URL="https://github.com/charmbracelet/gum/releases/download/v0.16.0/gum_0.16.0_Linux_x86_64.tar.gz"
echo "--> Using fixed download URL: $DOWNLOAD_URL"
# --- End Hardcoded URL ---

echo "--> Creating temporary directory..."
TMPDIR=$(mktemp -d)
echo "    Temp directory: $TMPDIR"
# Ensure cleanup happens on script exit
trap 'echo "--> Cleaning up temporary directory..."; rm -rf "$TMPDIR"' EXIT

FILENAME=$(basename "$DOWNLOAD_URL")
echo "--> Downloading $FILENAME..."
# Use -f to fail silently on HTTP errors, check exit code after curl command itself
curl -fsL --progress-bar "$DOWNLOAD_URL" -o "$TMPDIR/$FILENAME"
# set -e will exit here if curl fails

echo "--> Extracting gum..."
# Extract directly into the temp directory
tar -xzf "$TMPDIR/$FILENAME" -C "$TMPDIR"
# set -e handles tar failure

echo "--> Locating gum binary at $TMPDIR/gum..."
# Define expected path directly
sudo mv "$TMPDIR"/gum_*/gum /usr/bin/gum
sudo rm -rf "$TMPDIR"

echo ""
echo "✅ 'gum' installed successfully to /usr/bin/gum"
echo "   Verify with: gum --version"
gum --version

#Setup systemd service for dev command
sudo tee /etc/systemd/system/launch-dev.service > /dev/null <<'EOF'
[Unit]
Description=Call dev function from .glueopsrc
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=vscode
ExecStart=/bin/bash -c "source /home/vscode/.glueopsrc && dev"
RemainAfterExit=true

[Install]
WantedBy=multi-user.target

EOF

### Finish GUM install


dev() {
    if ! sudo systemctl is-enabled --quiet launch-dev.service; then
        sudo systemctl enable launch-dev.service
    fi
    # --- Tmux Handling ---
    # Ensure we are inside a tmux session named 'dev'
    if command -v tmux &> /dev/null && [ -z "$TMUX" ]; then
        if ! tmux attach-session -t dev 2>/dev/null; then
            gum style --padding "0 1" --foreground=245 "⏳ Creating new tmux session 'dev'..."
            tmux new-session -s dev -d
            tmux send-keys -t dev "dev" C-m
            tmux attach-session -t dev
            return 0
        fi
         gum style --padding "0 1" --foreground=245 "🔗 Attached to existing tmux session 'dev'."
    fi

    [ -z "$TMUX" ] && return 0

    # --- Configuration ---
    local CONTAINER_NAME="codespace"

    # --- Fetch Tags ---
    # Fetch tags regardless of whether container exists, to check for updates
    gum style --padding "0 1" --margin "1 0 0 0" "⚙️ Checking latest available image tags..."
    local api_url
    local latest_tag_name=""
    local all_tags=() # Initialize as empty array

    if [ "${ENVIRONMENT:-prod}" = "nonprod" ]; then
        gum style --border double --border-foreground=214 --padding "0 2" --margin "1 0" --bold \
            "⚠️ WARNING: RUNNING IN NONPROD ENVIRONMENT ⚠️"
        api_url="https://api-provisioner.glueopshosted.rocks/v1/get-images"
    else
        api_url="https://api-provisioner.glueopshosted.com/v1/get-images"
    fi

    local tag_json
    tag_json=$(gum spin --spinner dot --title "Fetching available image tags..." -- \
        curl --fail -s "$api_url"
    )
    local curl_exit_code=$?

    if [ $curl_exit_code -ne 0 ]; then
        gum style --padding "0 1" --foreground=196 --bold \
            "❌ ERROR:" "Failed to fetch tags from $api_url (curl exit code: $curl_exit_code)." >&2
        gum style --padding "0 1" --foreground=214 "⚠️ Warning: Cannot check for newer versions. Proceeding..."
        latest_tag_name="" # Ensure it's empty if fetch failed
    else
        # Get *all* tags first (assuming API returns sorted newest first)
        mapfile -t all_tags < <(echo "$tag_json" | jq -r '.images[]')
        if [ ${#all_tags[@]} -eq 0 ]; then
           gum style --padding "0 1" --foreground=214 \
            "⚠️ Warning: No tags found from API. Cannot check for newer versions."
           latest_tag_name="" # Ensure it's empty if no tags found
        else
           # Identify the absolute latest tag
           latest_tag_name="${all_tags[0]}"
           gum style --padding "0 1" --foreground=40 "✅ Latest available tag: $(gum style --bold "$latest_tag_name")"
        fi
    fi

    # --- Check if Container Exists ---
    gum style --padding "0 1" --margin "1 0 0 0" "🔎 Checking for existing container '$CONTAINER_NAME'..."
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        # --- Container Exists ---
        gum style --border normal --border-foreground=226 --padding "0 2" --margin "1 0" \
            "✅ Container '$CONTAINER_NAME' already exists." # Yellow border for info

        local STATUS; STATUS=$(sudo docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")
        local IMAGE_NAME_TAG; IMAGE_NAME_TAG=$(sudo docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME")
        # Extract tag from image string (e.g., image:tag -> tag)
        local existing_tag="${IMAGE_NAME_TAG#*:}"

        gum style --padding "0 1" --foreground=226 \
            "📦 Using existing image: $(gum style --bold "$IMAGE_NAME_TAG")"

        # --- Check for Newer Version ---
        if [[ -n "$latest_tag_name" && "$existing_tag" != "$latest_tag_name" ]]; then
            gum style --border double --border-foreground=214 --padding "1 2" --margin "1 0" \
                "🟠 UPDATE AVAILABLE! 🟠" \
                "" \
                "Your version:     $(gum style --bold "$existing_tag")" \
                "Latest version:   $(gum style --bold "$latest_tag_name")" \
                "" \
                "Consider deleting this environment and creating a" \
                "new one via Slack to get the latest updates." \
                "" \
                "$(gum style --bold --foreground=196 '⚠️ IMPORTANT:') Before deleting, ensure you" \
                "   $(gum style --bold --foreground=226 'commit')$(gum style --bold --foreground=196 ' and ')$(gum style --bold --foreground=226 'push')$(gum style --bold --foreground=196 ' ALL your work. Anything stored')" \
                "   only in this codespace $(gum style --bold --foreground=196 'will be lost.')"

            sleep 5
        elif [[ -n "$latest_tag_name" && "$existing_tag" == "$latest_tag_name" ]]; then
             gum style --padding "0 1" --foreground=40 "👍 You are running the latest version ($existing_tag)."
        fi
        # --- End Check for Newer Version ---


        if [ "$STATUS" = "running" ]; then
            gum style --padding "0 1" --foreground=40 "✅ Container is already running."
        else
            gum style --padding "0 1" --foreground=214 "🟡 Container is stopped. Attempting to start..."
            if ! gum spin --spinner dot --title "Starting existing container..." -- \
                sudo docker start "$CONTAINER_NAME"; then
                 gum style --padding "0 1" --foreground=196 --bold \
                    "❌ ERROR:" "Failed to start existing container '$CONTAINER_NAME'." >&2
                 return 1
            fi
             gum style --padding "0 1" --foreground=40 "✅ Container started successfully."
        fi

    else
        # --- Container Does Not Exist ---
        # We already fetched tags, need latest_tag_name and all_tags
        # allow images to be selected in the nonprod environment
        if [ "${ENVIRONMENT:-prod}" = "nonprod" ]; then
            if [[ -z "$latest_tag_name" ]]; then
                gum style --padding "0 1" --foreground=196 --bold \
                    "❌ ERROR:" "Cannot proceed without available image tags from API." >&2
                return 1
            fi

            gum style --border normal --border-foreground=226 --padding "0 2" --margin "1 0" \
                "🔎 Container '$CONTAINER_NAME' does not exist. Proceeding with setup."

            # Take the top 5 tags for display list
            mapfile -t tags_to_display < <(printf "%s\n" "${all_tags[@]}" | head -5)

            # --- Check Cached Images ---
            local cached_images
            cached_images=$(sudo docker images --format "{{.Repository}}:{{.Tag}}" | grep "ghcr.repo.gpkg.io/glueops/codespaces")

            # --- Prepare Options for Gum (Using Simplified Markers) ---
            local options=()

            for tag in "${tags_to_display[@]}"; do
                local display_tag="$tag" # Base display tag is just the tag name
                local is_latest=false
                local is_cached=false

                if [[ "$tag" == "$latest_tag_name" ]]; then
                    is_latest=true
                fi
                if echo "$cached_images" | grep -q ":${tag}$"; then
                    is_cached=true
                fi

                local marker=""
                if $is_latest && $is_cached; then marker=" [L, C]";
                elif $is_latest; then marker=" [L]";
                elif $is_cached; then marker=" [C]"; fi
                display_tag="$tag$marker"

                options+=("$display_tag")
            done
            options+=("Custom")

            # --- Use Gum Choose for Selection ---
            local selected_option
            selected_option=$(gum choose \
                --header "Please select a tag ([L]=Latest, [C]=Cached):" \
                --height 10 \
                "${options[@]}"
            )
            if [ $? -ne 0 ]; then gum style --padding "0 1" --foreground=214 "🟡 Selection cancelled."; return 1; fi
            if [ -z "$selected_option" ]; then gum style --padding "0 1" --foreground=196 --bold "❌ ERROR:" "No option selected." >&2; return 1; fi

            # --- Handle Selection (Using sed for Cleaning) ---
            local selected_tag

            if [ "$selected_option" == "Custom" ]; then
                selected_tag=$(gum input --placeholder "Enter custom tag:" --prompt "$(gum style --bold 'Custom Tag >') ")
                if [ $? -ne 0 ] || [ -z "$selected_tag" ]; then gum style --padding "0 1" --foreground=214 "🟡 Custom tag entry cancelled or empty."; return 1; fi
                gum style --padding "0 1" "🏷️ Using custom tag: $(gum style --bold "$selected_tag")"
            else
                selected_tag=$(echo "$selected_option" | sed -e 's/ \[L, C\]$//' -e 's/ \[L\]$//' -e 's/ \[C\]$//')
                selected_tag="${selected_tag%"${selected_tag##*[![:space:]]}"}"
                selected_tag="${selected_tag#"${selected_tag%%*[![:space:]]}"}"
                gum style --padding "0 1" "🏷️ Selected tag: $(gum style --bold "$selected_tag")"
            fi

            export CONTAINER_TAG_TO_USE="$selected_tag"
        fi
        # --- Create Container ---
        mkdir -p /workspaces/glueops # Silent

        gum style --padding "0 1" --foreground=226 \
            "🧼 Creating and starting new container '$CONTAINER_NAME' with tag $(gum style --bold "$CONTAINER_TAG_TO_USE")..."

        if ! gum spin --spinner dot --title "Creating container '$CONTAINER_NAME'..." --show-output -- \
            sudo docker run -itd --name "$CONTAINER_NAME" \
                --net=host \
                --cap-add=SYS_PTRACE \
                --security-opt seccomp=unconfined \
                --privileged \
                --init \
                --device=/dev/net/tun \
                -u "$(id -u):$(getent group docker | cut -d: -f3 || echo $(id -g))" \
                -v /workspaces/glueops:/workspaces/glueops \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock \
                -w /workspaces/glueops \
                "ghcr.repo.gpkg.io/glueops/codespaces:${CONTAINER_TAG_TO_USE}" bash; then
             gum style --padding "0 1" --foreground=196 --bold \
                "❌ ERROR:" "Failed to create or start container '$CONTAINER_NAME' with tag '$CONTAINER_TAG_TO_USE'." >&2
             # Added suggestion from previous step, kept simple
             gum style --padding "0 1" --foreground=214 \
                "🤔 Suggestion: Verify the tag exists and is accessible, or try a different tag." >&2
             sudo docker rm "$CONTAINER_NAME" &>/dev/null
             return 1
        fi
        gum style --padding "0 1" --foreground=40 \
            "✅ Container '$CONTAINER_NAME' created and started."
    fi # End of container exists check

    # --- Exec into Container ---
    local LOG_OPTIONS="--log off"
    if [ "$CODESPACE_ENABLE_VERBOSE_LOGS" = "true" ]; then
      LOG_OPTIONS="--verbose --log trace"
    fi

    gum style --border normal --border-foreground=240 --padding "0 2" --margin "1 0" \
        "🚀 Executing 'code tunnel' inside the container..."
    tmux switch-client -r

    if [ ! -f ~/.ssh/sish_tunnel_key_id_ed25519 ]; then
        ssh-keygen -t ed25519 -f ~/.ssh/sish_tunnel_key_id_ed25519 -N "" -C "sish_tunnel_key"
        chmod 600 ~/.ssh/sish_tunnel_key_id_ed25519
        chmod 644 ~/.ssh/sish_tunnel_key_id_ed25519.pub
    fi
    
    export AUTOSSH_GATETIME=0
    
    PID_FILE="/tmp/sish_tunnel.pid"
    # check for existing pid and kill it
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        
        # Check if process with this PID is actually running
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Stopping existing tunnel (PID: $OLD_PID)..."
            kill "$OLD_PID"
            # Optional: Wait a moment for it to close cleanly
            sleep 1
        else
            echo "Found PID file, but process $OLD_PID is not running. Cleaning up."
        fi
        
        # Remove the old file
        rm "$PID_FILE"
    fi
    
    [ -f /etc/glueops/cde_token ] && export CDE_TOKEN=$(cat /etc/glueops/cde_token)
    if [ -n "$CDE_TOKEN" ]; then
        AUTOSSH_PIDFILE="$PID_FILE" autossh -M 0 -f -N -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/sish_tunnel_key_id_ed25519 -p 2222 -l $HOSTNAME -R cde:80:localhost:8000 tunnels.glueopshosted.com
        sudo docker exec -it "$CONTAINER_NAME" bash -c "code serve-web --host 0.0.0.0 --accept-server-license-terms --port 8000 --connection-token $CDE_TOKEN"
    else
        sudo docker exec -it "$CONTAINER_NAME" bash -c "code tunnel --random-name $LOG_OPTIONS"
    fi

    local exec_status=$?
    if [ $exec_status -ne 0 ]; then
        gum style --padding "0 1" --foreground=214 \
            "👋 'code tunnel' exited (status: $exec_status)."
    fi

    return $exec_status
}

GLUEOPSRC="$(declare -f dev)"
echo "export CONTAINER_TAG_TO_USE=$GLUEOPS_CODESPACES_CONTAINER_TAG" | sudo tee -a /home/vscode/.glueopsrc
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
{ echo -e "\e[1;32m$(figlet GlueOps)\e[0m"; echo ""; echo -e "\e[1;34mTo get your codespace started, run the following command:\e[0m"; echo ""; echo -e "\e[1;33m    dev\e[0m"; echo ""; } | sudo tee /etc/motd

#Install tailscale
curl -fsSL https://tailscale.com/install.sh | sh



if [ -z "$GLUEOPS_CODESPACES_CONTAINER_TAG" ]; then
  echo "GLUEOPS_CODESPACES_CONTAINER_TAG is not set."
  echo "Please manually run: docker pull ghcr.repo.gpkg.io/glueops/codespaces:<TAG> before you run 'dev'"
else
  echo "Pulling down codespace version: $GLUEOPS_CODESPACES_CONTAINER_TAG"
  until sudo docker pull ghcr.repo.gpkg.io/glueops/codespaces:$GLUEOPS_CODESPACES_CONTAINER_TAG; do echo "Docker pull failed, retrying in 20 seconds..."; sleep 20; done
fi

echo -e "\n\n\n\n\nPlease reboot using: sudo reboot \n\n"


