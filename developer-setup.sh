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
# live-restore: restarting or upgrading dockerd leaves the codespace running. local driver: rotated logs.
sudo mkdir -p /etc/docker && echo '{"mtu": 1400, "log-driver": "local", "log-opts": {"max-size": "10m", "max-file": "3"}, "live-restore": true}' | sudo tee /etc/docker/daemon.json > /dev/null && sudo systemctl restart docker
sudo apt-get update --error-on=any
sudo apt install tmux jq figlet qemu-guest-agent incus-agent ripgrep -y
sudo apt-get clean
sudo mkdir -p /etc/qemu
printf '[general]\nblacklist =\n' | sudo tee /etc/qemu/qemu-ga.conf

#export DEBIAN_FRONTEND=noninteractive
#sudo apt-get -s dist-upgrade | grep "^Inst" | grep -i securi | awk -F " " {'print $2'} | xargs sudo apt-get install -y
sudo groupadd -f docker
sudo usermod -aG docker vscode
# Debian 13 (trixie) systemd-sysctl no longer reads /etc/sysctl.conf; use /etc/sysctl.d/.
echo 'fs.inotify.max_user_instances=1024' | sudo tee /etc/sysctl.d/99-glueops-codespaces.conf
echo 1024 | sudo tee /proc/sys/fs/inotify/max_user_instances



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

### Codespace supervision
# Everything the VM needs to keep the codespace running is embedded below, so the break-glass
# `curl setup.glueops.dev | bash` path stays a single file. Each file has its own quoted heredoc
# delimiter: the scripts contain heredocs of their own, and quoting keeps them uninterpolated here.
#   codespace-ensure   starts the codespace container, creating it if missing (root; boot + every minute)
#   codespace-tunnel   the sish reverse tunnel for the browser editor (vscode; restarted on exit)
#   dev                what people type: check/repair, status, logs, reset, and the `dev` tmux session
sudo install -d -m 0755 /usr/local/lib/codespace /etc/glueops

sudo tee /usr/local/lib/codespace/common.sh > /dev/null <<'CODESPACE_COMMON_EOF'
# Shared by codespace-ensure, codespace-tunnel and dev.
# shellcheck shell=bash disable=SC2034
CODESPACE_NAME=codespace
CODESPACE_IMAGE_REPO=ghcr.repo.gpkg.io/glueops/codespaces
CODESPACE_TAG_FILE=/etc/glueops/codespace-tag
CODESPACE_TOKEN_FILE=/etc/glueops/cde_token
CODESPACE_ENV_FILE=/etc/glueops/codespace.env
CODESPACE_LEGACY_ENDPOINT=tunnels.glueopshosted.com

# Regional sish endpoint written by cloud-init on newer VMs; older VMs have no file and stay on the
# legacy central tunnel.
codespace_tunnel_endpoint() {
    local endpoint=""
    [ -s /etc/glueops/tunnel_endpoint ] && endpoint="$(head -n1 /etc/glueops/tunnel_endpoint | tr -d '[:space:]')"
    echo "${endpoint:-$CODESPACE_LEGACY_ENDPOINT}"
}

# Legacy central sish runs --append-user-to-subdomain, so the VM binds "cde" and the URL becomes
# cde-<hostname>.<endpoint>; regional instances don't, so the VM binds its bare hostname. The Slack
# bot derives the access URL from the same rule (util/libvirt/libvirt-server.js cdeAccessUrl).
codespace_tunnel_bind() {
    if [ "$(codespace_tunnel_endpoint)" = "$CODESPACE_LEGACY_ENDPOINT" ]; then echo cde; else hostname; fi
}

codespace_url() {
    local endpoint
    endpoint="$(codespace_tunnel_endpoint)"
    if [ "$endpoint" = "$CODESPACE_LEGACY_ENDPOINT" ]; then
        echo "https://cde-$(hostname).$endpoint"
    else
        echo "https://$(hostname).$endpoint"
    fi
}
CODESPACE_COMMON_EOF

sudo tee /usr/local/bin/codespace-ensure > /dev/null <<'CODESPACE_ENSURE_EOF'
#!/usr/bin/env bash
# codespace-ensure: start the codespace container, creating it if it doesn't exist.
# Run as root by codespace-ensure.service, at boot and every minute from codespace-ensure.timer.
# The container restarts itself (--restart unless-stopped); this covers the cases Docker doesn't:
# first boot, a start that failed (e.g. its init was OOM-killed, after which Docker gives up), and
# a container someone removed.
set -euo pipefail
# shellcheck source=/dev/null
. /usr/local/lib/codespace/common.sh

exec 9> /run/lock/codespace-ensure.lock
flock 9

docker info > /dev/null 2>&1 || { echo "docker is not reachable; retrying on the next run" >&2; exit 1; }

create() {
    local tag gid image
    tag="$(tr -d '[:space:]' < "$CODESPACE_TAG_FILE" 2> /dev/null || true)"
    if [ -z "$tag" ]; then
        echo "no image tag in $CODESPACE_TAG_FILE; run: dev reset" >&2
        exit 1
    fi
    image="$CODESPACE_IMAGE_REPO:$tag"
    gid="$(getent group docker | cut -d: -f3)"
    install -d -o vscode -g vscode /workspaces/glueops
    # docker run --env-file errors if the file is missing; an empty file is zero vars.
    touch "$CODESPACE_ENV_FILE"
    chmod 600 "$CODESPACE_ENV_FILE"

    # The main process is chosen once, at create time: the browser editor when the Slack bot wrote a
    # connection token, otherwise a VS Code tunnel that prints a GitHub device code to `docker logs`.
    # code-tunnel is called directly: the `code` wrapper adds a ~100MB Electron parent for nothing.
    local cmd
    if [ -s "$CODESPACE_TOKEN_FILE" ]; then
        # stdout carries "Web UI available at ...?tkn=<token>", so it goes nowhere; errors are on stderr.
        cmd='[ -s /etc/glueops/cde_token ] || exit 1; cde-trust-serve-web || true; exec /usr/share/code/bin/code-tunnel serve-web --host 127.0.0.1 --port 8000 --accept-server-license-terms --connection-token-file /etc/glueops/cde_token > /dev/null'
    else
        cmd='exec /usr/share/code/bin/code-tunnel tunnel --random-name --accept-server-license-terms'
    fi
    echo "creating $CODESPACE_NAME from $image"
    # /var/run/tailscale is bound as a directory: a bound socket *file* that is missing at start
    # makes Docker create a directory there and the start fails. /etc/glueops likewise, so a file
    # written after create still shows up.
    docker run -d --name "$CODESPACE_NAME" --restart unless-stopped --init \
        --net=host --privileged --cap-add=SYS_PTRACE --security-opt seccomp=unconfined --device=/dev/net/tun \
        -u "1337:$gid" -w /workspaces/glueops \
        -v /workspaces/glueops:/workspaces/glueops \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /var/run/tailscale:/var/run/tailscale \
        -v /etc/glueops:/etc/glueops:ro \
        --env-file "$CODESPACE_ENV_FILE" \
        "$image" bash -lc "$cmd" > /dev/null
}

started=0
if running="$(docker container inspect -f '{{.State.Running}}' "$CODESPACE_NAME" 2>&1)"; then
    if [ "$running" != true ]; then
        echo "starting $CODESPACE_NAME"
        docker start "$CODESPACE_NAME" > /dev/null
        started=1
    fi
elif grep -qi 'no such container' <<< "$running"; then
    create
    started=1
else
    echo "docker container inspect failed: $running" >&2
    exit 1
fi

if [ "$started" = 1 ]; then
    # One-time setup inside the container (sentinel-guarded). It tees its own log to ~/.cde-init.log;
    # its output can echo secrets from codespace.env, so it stays out of the journal.
    docker exec --env-file "$CODESPACE_ENV_FILE" "$CODESPACE_NAME" bash -lc 'command -v cde-boot > /dev/null && cde-boot || true' > /dev/null 2>&1 \
        || echo "cde-boot failed (non-fatal); see ~/.cde-init.log in the container" >&2
fi

# The tunnel unit is wanted at boot, but a token can arrive later (or cloud-init may not run at all).
if [ -s "$CODESPACE_TOKEN_FILE" ]; then
    systemctl start --no-block codespace-tunnel.service
fi
CODESPACE_ENSURE_EOF

sudo tee /usr/local/bin/codespace-tunnel > /dev/null <<'CODESPACE_TUNNEL_EOF'
#!/usr/bin/env bash
# codespace-tunnel: the sish reverse tunnel for the browser editor on 127.0.0.1:8000.
# Run as vscode by codespace-tunnel.service, which restarts it whenever ssh exits.
set -euo pipefail
# shellcheck source=/dev/null
. /usr/local/lib/codespace/common.sh

key="$HOME/.ssh/sish_tunnel_key_id_ed25519"
if [ ! -f "$key" ]; then
    umask 077
    mkdir -p "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N "" -C sish_tunnel_key -f "$key"
fi

host="$(hostname)"
# ExitOnForwardFailure + ServerAlive*: a refused forward or a dead path makes ssh exit, so systemd
# reconnects instead of leaving a connected ssh with no tunnel.
# IdentitiesOnly: sish pins the first key it accepts per username; never let an agent key win that.
exec ssh -N -T \
    -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o IdentitiesOnly=yes -i "$key" \
    -p 2222 -l "$host" -R "$(codespace_tunnel_bind):80:localhost:8000" "$(codespace_tunnel_endpoint)"
CODESPACE_TUNNEL_EOF

sudo tee /usr/local/bin/dev > /dev/null <<'CODESPACE_DEV_EOF'
#!/usr/bin/env bash
# dev: check on and repair the codespace.
#   dev          make sure the codespace is up, show its status, open the `dev` tmux session
#   dev status   print status; exit 0 if healthy, 1 if not
#   dev logs     follow the codespace's logs (the `logs` window of the tmux session runs this)
#   dev reset    delete the codespace container and its volumes and create it again
#                (with ENVIRONMENT=nonprod it asks which image tag to use)
set -euo pipefail

# Everything runs as vscode; root (or anyone else) is switched over, keeping the arguments.
if [ "$(id -un)" != vscode ]; then
    exec sudo -u vscode -H -- env ENVIRONMENT="${ENVIRONMENT:-}" /usr/local/bin/dev "$@"
fi
# shellcheck source=/dev/null
. /usr/local/lib/codespace/common.sh

ENVIRONMENT="${ENVIRONMENT:-prod}"

# web: the browser editor (serve-web); tunnel: a VS Code tunnel (device-code login); missing.
codespace_mode() {
    local cmd
    cmd="$(docker container inspect -f '{{json .Config.Cmd}}' "$CODESPACE_NAME" 2> /dev/null)" || { echo missing; return; }
    case "$cmd" in
        *serve-web*) echo web ;;
        *) echo tunnel ;;
    esac
}

# Prints one line per part and returns 0 only if the codespace is usable.
status() {
    local healthy=0 info state running started restarts oom code err image
    if ! info="$(docker container inspect -f '{{.State.Status}}|{{.State.Running}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.State.ExitCode}}|{{.Config.Image}}|{{.State.Error}}' "$CODESPACE_NAME" 2> /dev/null)"; then
        echo "  container  missing - codespace-ensure creates it within a minute"
        echo "             (progress: sudo journalctl -u codespace-ensure -n 20)"
        return 1
    fi
    IFS='|' read -r state running started restarts oom code image err <<< "$info"
    local line="  container  $state  ${image##*:}  restarts=$restarts"
    [ "$restarts" != 0 ] && line+="  last exit=$code"
    [ "$oom" = true ] && line+=" (OOM-killed)"
    echo "$line"
    [ -n "$err" ] && echo "             error: $err"
    if [ "$running" != true ] || [ "$state" = restarting ]; then
        healthy=1
        echo "             if it stays down: dev reset (deletes the container and its volumes)"
    fi

    case "$(codespace_mode)" in
        web)
            local http
            http="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8000/ || true)"
            if [ "$http" != 000 ] && [ -n "$http" ]; then
                echo "  editor     up (127.0.0.1:8000)"
            else
                echo "  editor     not answering on 127.0.0.1:8000"
                healthy=1
            fi
            if systemctl is-active --quiet codespace-tunnel.service; then
                echo "  tunnel     up  restarts=$(systemctl show -p NRestarts --value codespace-tunnel.service)"
            else
                echo "  tunnel     $(systemctl is-active codespace-tunnel.service || true)  (sudo journalctl -u codespace-tunnel -n 20)"
                healthy=1
            fi
            echo "  url        $(codespace_url)  (use your Slack link: it carries your token)"
            ;;
        tunnel)
            local js tstate tname devcode
            js="$(docker exec "$CODESPACE_NAME" /usr/share/code/bin/code-tunnel tunnel status 2> /dev/null || true)"
            tstate="$(jq -r '.tunnel.tunnel // empty' <<< "$js" 2> /dev/null || true)"
            tname="$(jq -r '.tunnel.name // empty' <<< "$js" 2> /dev/null || true)"
            if [ "$tstate" = Connected ]; then
                echo "  tunnel     connected  https://vscode.dev/tunnel/$tname/workspaces/glueops"
            else
                healthy=1
                # It prints a fresh code on its own about every 15 minutes; only the latest one works.
                devcode="$(docker logs --since "$started" "$CODESPACE_NAME" 2>&1 | grep -o 'login/device and use code [A-Z0-9-]*' | tail -n1 | awk '{print $NF}' || true)"
                if [ -n "$devcode" ] && [ -z "$tname" ]; then
                    echo "  tunnel     waiting for login: open https://github.com/login/device and enter $devcode"
                else
                    echo "  tunnel     ${tstate:-starting}  (dev logs)"
                fi
            fi
            [ -s "$CODESPACE_TOKEN_FILE" ] && echo "  note       a connection token exists but the codespace is in tunnel mode: dev reset"
            ;;
    esac
    echo "  disk       $(df -h --output=avail / | tail -n1 | tr -d ' ') free on /"
    return "$healthy"
}

wait_healthy() {
    for _ in $(seq 1 30); do
        status > /dev/null && return 0
        sleep 1
    done
    return 1
}

# Runs codespace-ensure now and waits for it, showing what it does: a first create can take minutes.
ensure_now() {
    local follower
    sudo journalctl -f -n 0 -o cat -u codespace-ensure.service &
    follower=$!
    sudo systemctl start codespace-ensure.service || echo "codespace-ensure failed; status below"
    kill "$follower" 2> /dev/null || true
    wait "$follower" 2> /dev/null || true
}

update_notice() {
    local api latest current
    api=https://api-provisioner.glueopshosted.com/v1/get-images
    [ "$ENVIRONMENT" = nonprod ] && api=https://api-provisioner.glueopshosted.rocks/v1/get-images
    latest="$(curl -fs --max-time 5 "$api" | jq -r '.images[0] // empty' 2> /dev/null || true)"
    current="$(docker container inspect -f '{{.Config.Image}}' "$CODESPACE_NAME" 2> /dev/null || true)"
    current="${current##*:}"
    if [ -n "$latest" ] && [ -n "$current" ] && [ "$latest" != "$current" ]; then
        echo "  update     $latest is available (you have $current). Commit and push your work, then create a new codespace in Slack."
    fi
}

logs() {
    trap 'echo; echo "(Ctrl-C does not stop anything here; detach from tmux with Ctrl-b d)"' INT
    local since="" last_start="" info running started
    while :; do
        case "$(codespace_mode)" in
            web)
                sudo journalctl -f -n 30 -u codespace-tunnel.service -u codespace-ensure.service || true
                ;;
            tunnel)
                # The device code and tunnel link are on the container's stdout. docker logs -f exits
                # when the container stops, so follow only while it runs, from where we left off.
                info="$(docker container inspect -f '{{.State.Running}} {{.State.StartedAt}}' "$CODESPACE_NAME" 2> /dev/null || true)"
                read -r running started <<< "$info"
                if [ "$running" = true ]; then
                    [ "$started" != "$last_start" ] && since="$started" && last_start="$started"
                    docker logs -f --since "$since" "$CODESPACE_NAME" 2>&1 || true
                    since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                else
                    sleep 5
                fi
                ;;
            missing)
                echo "$(date +%T) no codespace container yet; codespace-ensure creates it"
                sleep 10
                ;;
        esac
        sleep 2
    done
}

pick_tag() {
    local api tags tag
    api=https://api-provisioner.glueopshosted.rocks/v1/get-images
    mapfile -t tags < <(curl -fs --max-time 10 "$api" | jq -r '.images[]' 2> /dev/null | head -n5)
    tag="$(gum choose --header "Image tag for the new codespace:" "${tags[@]}" Custom)"
    [ "$tag" = Custom ] && tag="$(gum input --placeholder "image tag")"
    [ -n "$tag" ] || { echo "no tag chosen" >&2; return 1; }
    echo "$tag"
}

reset() {
    [ -t 0 ] && [ -t 1 ] || { echo "dev reset needs a terminal" >&2; exit 1; }
    gum confirm "Delete the codespace container and create it again?" || exit 1
    local tag=""
    [ "$ENVIRONMENT" = nonprod ] && tag="$(pick_tag)"
    # Stop the timer first so codespace-ensure can't recreate the container from the old tag midway.
    sudo systemctl stop codespace-ensure.timer
    docker rm -f "$CODESPACE_NAME" > /dev/null 2>&1 || true
    [ -n "$tag" ] && echo "$tag" | sudo tee "$CODESPACE_TAG_FILE" > /dev/null
    sudo systemctl start codespace-ensure.timer
    ensure_now
}

tmux_session() {
    # One chained command: if two `dev`s race, the second fails on "duplicate session" and adds nothing.
    tmux has-session -t =dev 2> /dev/null \
        || tmux new-session -d -s dev -n logs "dev status; dev logs" \; new-window -d -t =dev -n shell \
        || true
    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t =dev
    else
        exec tmux attach -t =dev
    fi
}

main() {
    case "${1:-}" in
        status) status ;;
        logs) logs ;;
        reset) reset; status || true ;;
        "")
            if [ -t 0 ] && [ -t 1 ]; then
                echo "Checking the codespace..."
                ensure_now
                wait_healthy || true
                status || true
                update_notice
                # Typed inside the `dev` session: the status above is the whole answer.
                if [ -n "${TMUX:-}" ] && [ "$(tmux display-message -p '#S')" = dev ]; then exit 0; fi
                tmux_session
            else
                # No terminal, e.g. the Slack bot's first-boot call from inside cloud-final: a blocking
                # start would wait for cloud-final to finish, which is waiting for us.
                sudo systemctl start --no-block codespace-ensure.service
                status || true
            fi
            ;;
        -h | --help | help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) echo "unknown command: $1 (try: dev help)" >&2; exit 2 ;;
    esac
}

main "$@"
CODESPACE_DEV_EOF

sudo chmod 0755 /usr/local/bin/codespace-ensure /usr/local/bin/codespace-tunnel /usr/local/bin/dev

sudo tee /etc/systemd/system/codespace-ensure.service > /dev/null <<'CODESPACE_ENSURE_UNIT_EOF'
[Unit]
Description=Start or create the codespace container
# Wanted by cloud-init.target, not multi-user.target: cloud-final.service is ordered after
# multi-user.target, so a multi-user unit ordered after cloud-final forms an ordering cycle and
# systemd silently drops the job at boot.
After=network-online.target docker.service tailscaled.service cloud-final.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/codespace-ensure
# The first create pulls the image if needed and copies the image's home into the new container.
TimeoutStartSec=20min

[Install]
WantedBy=cloud-init.target
CODESPACE_ENSURE_UNIT_EOF

sudo tee /etc/systemd/system/codespace-ensure.timer > /dev/null <<'CODESPACE_ENSURE_TIMER_EOF'
[Unit]
Description=Re-check the codespace container every minute

[Timer]
OnBootSec=3min
OnUnitInactiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
CODESPACE_ENSURE_TIMER_EOF

sudo tee /etc/systemd/system/codespace-tunnel.service > /dev/null <<'CODESPACE_TUNNEL_UNIT_EOF'
[Unit]
Description=sish reverse tunnel for the codespace editor
After=network-online.target cloud-final.service
Wants=network-online.target
ConditionFileNotEmpty=/etc/glueops/cde_token
StartLimitIntervalSec=0

[Service]
User=vscode
ExecStart=/usr/local/bin/codespace-tunnel
Restart=always
# Flat on purpose: RestartSteps never resets after a healthy run, so a stepped backoff ends up at
# its maximum for every later drop.
RestartSec=5s
# A few MB of ssh carries everyone's access; let the kernel pick something else under memory pressure.
OOMScoreAdjust=-500

[Install]
WantedBy=cloud-init.target
CODESPACE_TUNNEL_UNIT_EOF

# Docker starts the container itself at boot; give tailscaled the chance to create its socket first.
sudo install -d -m 0755 /etc/systemd/system/docker.service.d /etc/systemd/system/tailscaled.service.d
printf '[Unit]\nAfter=tailscaled.service\n' | sudo tee /etc/systemd/system/docker.service.d/after-tailscaled.conf > /dev/null
# Keep /run/tailscale across tailscaled restarts (e.g. upgrades) so the container's bind of it stays valid.
printf '[Service]\nRuntimeDirectoryPreserve=yes\n' | sudo tee /etc/systemd/system/tailscaled.service.d/preserve-rundir.conf > /dev/null

sudo systemctl daemon-reload
# Enabled, not started: at image build there is no token or tag yet; the first boot starts them.
sudo systemctl enable codespace-ensure.service codespace-ensure.timer codespace-tunnel.service

# Fetch latest release if GLUEOPS_CODESPACES_CONTAINER_TAG is not set
if [ -z "$GLUEOPS_CODESPACES_CONTAINER_TAG" ]; then
  echo "GLUEOPS_CODESPACES_CONTAINER_TAG is not set. Fetching latest release..."
  GLUEOPS_CODESPACES_CONTAINER_TAG=$(curl -fsSL "https://api.github.com/repos/GlueOps/codespaces/releases/latest" | jq -r '.tag_name')

  if [ -z "$GLUEOPS_CODESPACES_CONTAINER_TAG" ] || [ "$GLUEOPS_CODESPACES_CONTAINER_TAG" == "null" ]; then
    echo "WARNING: Failed to fetch latest release tag. The codespace won't start until a tag is set (dev reset)."
    GLUEOPS_CODESPACES_CONTAINER_TAG=""
  else
    echo "Using latest release version: $GLUEOPS_CODESPACES_CONTAINER_TAG"
  fi
fi
# The image tag codespace-ensure creates the container from; `dev reset` can change it on nonprod.
[ -n "$GLUEOPS_CODESPACES_CONTAINER_TAG" ] && echo "$GLUEOPS_CODESPACES_CONTAINER_TAG" | sudo tee /etc/glueops/codespace-tag > /dev/null
# Kept, empty: the Slack bot's first-boot cloud-init runs `source ~/.glueopsrc; dev`.
echo "# dev is /usr/local/bin/dev; this file is kept for callers that still source it." | sudo tee /home/vscode/.glueopsrc > /dev/null

sudo chown -R vscode:vscode /home/vscode
sudo mkdir -p /workspaces
sudo chown -R vscode:vscode /workspaces
# disables the password for the current user (ex. root/admin/ubuntu users)
sudo passwd -d $USER
server_ip=$(echo $SSH_CONNECTION | awk '{print $3}')
echo ""
echo ""
#sudo figlet GlueOps | sudo tee /etc/motd
{ echo -e "\e[1;32m$(figlet GlueOps)\e[0m"; echo ""; echo -e "\e[1;34mYour codespace starts automatically. To check on it or repair it, run:\e[0m"; echo ""; echo -e "\e[1;33m    dev\e[0m"; echo ""; } | sudo tee /etc/motd

#Install tailscale
curl -fsSL https://tailscale.com/install.sh | sh



if [ -z "$GLUEOPS_CODESPACES_CONTAINER_TAG" ]; then
  echo "GLUEOPS_CODESPACES_CONTAINER_TAG is not set."
  echo "Please manually run: docker pull ghcr.repo.gpkg.io/glueops/codespaces:<TAG> before you run 'dev'"
else
  echo "Pulling down codespace version: $GLUEOPS_CODESPACES_CONTAINER_TAG"
  until sudo docker pull ghcr.repo.gpkg.io/glueops/codespaces:$GLUEOPS_CODESPACES_CONTAINER_TAG; do echo "Docker pull failed, retrying in 20 seconds..."; sleep 20; done

  # Pre-warm the Ansible shell image (used by gluekube_ssh --ansible) so the
  # first use on a fresh VM doesn't pay a ~300MB pull. The digest-pinned
  # reference lives in ONE place - the ANSIBLE_IMAGE= line of the gluekube_ssh
  # tool inside the CDE image we just pulled - so extract it from there rather
  # than duplicating the pin here. Best-effort on every path: an older CDE
  # image without the pin, or a failed pull, just means gluekube_ssh pulls the
  # image on first use like it already handles.
  ANSIBLE_SHELL_IMAGE=$(sudo docker run --rm --entrypoint "" \
      "ghcr.repo.gpkg.io/glueops/codespaces:$GLUEOPS_CODESPACES_CONTAINER_TAG" \
      sed -n 's/^ANSIBLE_IMAGE="\(.*\)"$/\1/p' /usr/local/bin/gluekube_ssh || true)
  if [ -n "$ANSIBLE_SHELL_IMAGE" ]; then
    echo "Pre-warming Ansible shell image: $ANSIBLE_SHELL_IMAGE"
    sudo docker pull "$ANSIBLE_SHELL_IMAGE" || echo "WARNING: Ansible shell image pre-warm failed; it will be pulled on first use instead."
  else
    echo "No Ansible shell image pin found in this codespace tag (pre-ansible-shell release?); skipping pre-warm."
  fi
fi

echo "disk usage after docker pull:"
df -h /
sudo du -sh /var/lib/docker 2>/dev/null || true

echo -e "\n\n\n\n\nPlease reboot using: sudo reboot \n\n"


