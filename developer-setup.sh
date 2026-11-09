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
# live-restore: restarting dockerd (or a patch upgrade) leaves the codespace running. local driver: rotated logs.
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

### Install ttyd: the browser shells (codespace-ttyd). Not packaged in Debian 13; pinned by hand.
TTYD_URL=https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64
TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
# -p /tmp: the gum block above points TMPDIR at a directory it has since deleted.
ttyd_tmp="$(mktemp -p /tmp)"
curl -fsSL --retry 5 --retry-all-errors --connect-timeout 10 "$TTYD_URL" -o "$ttyd_tmp"
echo "$TTYD_SHA256  $ttyd_tmp" | sha256sum -c --quiet
sudo install -m 0755 "$ttyd_tmp" /usr/local/bin/ttyd
rm -f "$ttyd_tmp"

### Codespace supervision
# Everything the VM needs to keep the codespace running is embedded below, so the break-glass
# `curl setup.glueops.dev | bash` path stays a single file. Each file has its own quoted heredoc
# delimiter: the scripts contain heredocs of their own, and quoting keeps them uninterpolated here.
sudo install -d -m 0755 /usr/local/lib/codespace /etc/glueops

sudo tee /usr/local/lib/codespace/common.sh > /dev/null <<'CODESPACE_COMMON_EOF'
# Shared by codespace-ensure, codespace-tunnel, codespace-ttyd and dev.
# shellcheck shell=bash disable=SC2034
CODESPACE_NAME=codespace
CODESPACE_IMAGE_REPO=ghcr.repo.gpkg.io/glueops/codespaces
CODESPACE_TAG_FILE=/etc/glueops/codespace-tag
CODESPACE_CDE_TOKEN_FILE=/etc/glueops/cde_token
CODESPACE_SHELL_TOKEN_FILE=/etc/glueops/shell_token
CODESPACE_ENV_FILE=/etc/glueops/codespace.env
CODESPACE_ENDPOINT_FILE=/etc/glueops/tunnel_endpoint

# The regional sish endpoint, written by cloud-init; empty when the file is missing.
codespace_tunnel_endpoint() {
    [ -s "$CODESPACE_ENDPOINT_FILE" ] || return 0
    head -n1 "$CODESPACE_ENDPOINT_FILE" | tr -d '[:space:]'
}

# What the VM serves through sish, by id (README "Browser shells"): the editor, the codespace shell (inside
# the container) and the VM shell. Each has a codespace-tunnel@<id>; the shells also a codespace-ttyd@<id>.
CODESPACE_ACCESS="editor shell vm"

# The sish name each id binds: the editor its bare hostname, the shells <id>-<hostname>. The Slack bot
# derives the access URLs from the same rule (util/codespace-links.js).
codespace_bind() {
    case "$1" in
        editor) hostname ;;
        shell | vm) echo "$1-$(hostname)" ;;
    esac
}

codespace_url() {
    echo "https://$(codespace_bind "$1").$(codespace_tunnel_endpoint)"
}

codespace_port() {
    case "$1" in
        editor) echo 8000 ;;
        vm) echo 7681 ;;
        shell) echo 7682 ;;
    esac
}

# The file whose token turns each id on; both shells share one password.
codespace_token_file() {
    case "$1" in
        editor) echo "$CODESPACE_CDE_TOKEN_FILE" ;;
        shell | vm) echo "$CODESPACE_SHELL_TOKEN_FILE" ;;
    esac
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

# The tunnels don't need Docker: the VM shell must come up when the container is broken. Every run,
# so a token that arrives late is picked up within a minute; a disabled tunnel stays off.
for t in $CODESPACE_ACCESS; do
    if [ -s "$(codespace_token_file "$t")" ] && systemctl is-enabled --quiet "codespace-tunnel@$t.service"; then
        systemctl start --no-block "codespace-tunnel@$t.service" || echo "couldn't start codespace-tunnel@$t" >&2
    fi
done

docker info > /dev/null 2>&1 || { echo "docker is not reachable; retrying on the next run" >&2; exit 1; }

create() {
    local tag gid image
    tag="$(tr -d '[:space:]' < "$CODESPACE_TAG_FILE" 2> /dev/null || true)"
    if [ -z "$tag" ]; then
        echo "no image tag in $CODESPACE_TAG_FILE; write one there (e.g. v0.163.0)" >&2
        exit 1
    fi
    image="$CODESPACE_IMAGE_REPO:$tag"
    gid="$(getent group docker | cut -d: -f3)"
    install -d -o vscode -g vscode /workspaces/glueops
    # docker run --env-file errors if the file is missing; an empty file is zero vars.
    touch "$CODESPACE_ENV_FILE"
    chmod 600 "$CODESPACE_ENV_FILE"

    # Home and /nix live in named volumes so a recreated container keeps dotfiles, logins and
    # devbox/nix packages. Docker copies the image's content into each volume once, while it's empty;
    # the two go together because the nix profile links in home point into /nix.
    docker volume inspect codespace-home > /dev/null 2>&1 \
        || echo "first start: copying the image's home and /nix into new volumes; this takes a few minutes"

    # The main process is chosen once, at create time: the browser editor when the Slack bot wrote a
    # connection token, otherwise a VS Code tunnel that prints a GitHub device code to `docker logs`.
    # code-tunnel is called directly: the `code` wrapper adds a ~100MB Electron parent for nothing.
    local cmd
    if [ -s "$CODESPACE_CDE_TOKEN_FILE" ]; then
        # stdout carries "Web UI available at ...?tkn=<token>", so it goes nowhere; errors are on stderr.
        # --commit-id pins the server baked into the image: without it serve-web fetches each new VS Code
        # release on a browser connect (~700 MB) and runs it without cde-trust-serve-web's shim.
        cmd='[ -s /etc/glueops/cde_token ] || exit 1; cde-trust-serve-web || true; d=$(ls -d "$HOME"/.vscode/cli/serve-web/*/ 2> /dev/null | grep -v "\.staging" | tail -n 1); d=${d%/}; c=${d##*/}; exec /usr/share/code/bin/code-tunnel serve-web ${c:+--commit-id "$c"} --disable-telemetry --host 127.0.0.1 --port 8000 --accept-server-license-terms --connection-token-file /etc/glueops/cde_token > /dev/null'
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
        -v codespace-home:/home/vscode -v codespace-nix:/nix \
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
CODESPACE_ENSURE_EOF

sudo tee /usr/local/bin/codespace-tunnel > /dev/null <<'CODESPACE_TUNNEL_EOF'
#!/usr/bin/env bash
# codespace-tunnel editor|shell|vm: one sish reverse tunnel, from <id>'s URL to its port on 127.0.0.1 (common.sh).
# Run as vscode by codespace-tunnel@<id>, which restarts it whenever ssh exits. --check <id> is that unit's
# ExecCondition: the unit is skipped while the token or endpoint is missing.
set -euo pipefail
# shellcheck source=/dev/null
. /usr/local/lib/codespace/common.sh

if [ "${1:-}" = --check ]; then
    [ -s "$(codespace_token_file "${2:-}")" ] && [ -n "$(codespace_tunnel_endpoint)" ]
    exit
fi
port="$(codespace_port "${1:-}")"
if [ -z "$port" ]; then
    echo "usage: codespace-tunnel editor|shell|vm" >&2
    exit 2
fi

key="$HOME/.ssh/sish_tunnel_key_id_ed25519"
# Both tunnels start together at first boot, and sish pins the first key it sees for this VM's
# username: only one of them may create the key.
umask 077
mkdir -p "$HOME/.ssh"
(
    flock 8
    [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -C sish_tunnel_key -f "$key"
) 8> "$HOME/.ssh/.sish_tunnel_key.lock"

endpoint="$(codespace_tunnel_endpoint)"
if [ -z "$endpoint" ]; then
    echo "codespace-tunnel: no endpoint in $CODESPACE_ENDPOINT_FILE" >&2
    exit 1
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
    -p 2222 -l "$host" -R "$(codespace_bind "$1"):80:localhost:$port" "$endpoint"
CODESPACE_TUNNEL_EOF

sudo tee /usr/local/bin/codespace-ttyd > /dev/null <<'CODESPACE_TTYD_EOF'
#!/usr/bin/env bash
# codespace-ttyd shell|vm: a browser shell, served by ttyd on 127.0.0.1 and reached through codespace-tunnel@<id>:
# shell is a login shell inside the codespace container, vm one on the VM itself. Sign-in: user vscode, password
# /etc/glueops/shell_token. Run as vscode by codespace-ttyd@<id>.
# codespace-ttyd --connect is the codespace shell's command for each browser connection.
set -euo pipefail
# shellcheck source=/dev/null
. /usr/local/lib/codespace/common.sh

container_state() {
    local out
    if out="$(timeout 10 docker container inspect -f '{{.State.Status}} {{.State.StartedAt}}' "$CODESPACE_NAME" 2> /dev/null)"; then
        echo "$out"
    elif timeout 10 docker info > /dev/null 2>&1; then
        echo missing
    else
        echo docker-down
    fi
}

# A docker exec whose client goes away leaves its shell running in the container, so this connection's
# sessions there are hung up, as a real hangup would: each shell its docker execs started (tagged with
# CODESPACE_SHELL_ID, its parent outside the container) and everything in their sessions. tmux, screen and
# setsid'd jobs have sessions of their own and keep running. As root, to reach a sudo'd shell too.
cleanup() {
    timeout 10 docker exec -u 0 "$CODESPACE_NAME" sh -c '
        sids=
        for p in /proc/[0-9]*; do
            grep -qxzF "CODESPACE_SHELL_ID=$1" "$p/environ" 2> /dev/null || continue
            set -- "$1" $(sed "s/^.*) //" "$p/stat" 2> /dev/null)   # state ppid pgrp session ...
            [ "${3:-}" = 0 ] && sids="$sids $5 "
        done
        [ -n "$sids" ] || exit 0
        for p in /proc/[0-9]*; do
            s=$(sed "s/^.*) //" "$p/stat" 2> /dev/null | cut -d" " -f4)
            case "$sids" in *" $s "*) [ -n "$s" ] && kill -HUP "${p#/proc/}" ;; esac
        done; true' sh "$id" < /dev/null > /dev/null 2>&1 || true
}

connect() {
    id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    trap cleanup EXIT
    trap 'exit 129' HUP TERM
    local state rc
    while :; do
        state="$(container_state)"
        if [ "${state%% *}" = running ]; then
            # No -u or -w: the shell gets the container's user (with its docker group), directory and
            # environment, like the editor's terminal. The detach keys are moved off Ctrl-P, which shells use.
            rc=0
            docker exec -it -e TERM -e COLORTERM -e LANG -e "CODESPACE_SHELL_ID=$id" --detach-keys=ctrl-^,ctrl-^ \
                "$CODESPACE_NAME" sh -c 'exec "$(getent passwd "$(id -u)" | cut -d: -f7)" -l' || rc=$?
            # A normal exit ends the page; a container that stopped under the shell brings back the waiting
            # screen. A container being killed can still read as running for a moment, so wait before checking
            # after a failed exec. Before waiting, hang up what the exec left (a live-restored dockerd restart).
            [ "$rc" = 0 ] || sleep 2
            [ "$(container_state)" = "$state" ] && exit "$rc"
            cleanup
            continue
        fi
        case "${state%% *}" in
            missing) echo "The codespace container is being created (by codespace-ensure, or dev reset)." ;;
            restarting) echo "The codespace container is restarting." ;;
            removing) echo "The codespace container is being removed; codespace-ensure creates it again within a minute." ;;
            docker-down) echo "Docker isn't answering on the VM." ;;
            *) echo "The codespace container is ${state%% *}; codespace-ensure starts it within a minute." ;;
        esac
        echo "This page connects when it's up (Enter checks now). To see why: open the VM shell at"
        echo "$(codespace_url vm) and run: dev status"
        echo
        # read times out (> 128) to check again; anything else is Enter, or the page closing.
        read -r -t 5 _ || [ $? -gt 128 ] || exit 0
    done
}

case "${1:-}" in
    --connect) connect ;;
    shell) title="Codespace shell - $(hostname)" cmd=(/usr/local/bin/codespace-ttyd --connect) ;;
    vm) title="VM shell - $(hostname)" cmd=(bash -l) ;;
    *) echo "usage: codespace-ttyd shell|vm" >&2; exit 2 ;;
esac
token="$(cat "$CODESPACE_SHELL_TOKEN_FILE" 2> /dev/null || true)"
# ttyd keeps the credential in 256-byte buffers and fails every login, silently, past about 180.
if ! [[ "$token" =~ ^[A-Za-z0-9]{32,128}$ ]]; then
    echo "codespace-ttyd: $CODESPACE_SHELL_TOKEN_FILE is missing or isn't 32-128 letters and digits" >&2
    exit 1
fi
# ttyd has no credential-file option, so the token is on its command line, and journald stores the
# command line with every line a process logs: ttyd's output is discarded. -d 3 as well: ttyd logs the
# credential at notice level. -O: refuse websockets opened from other origins (every tunnel shares the
# SSO cookie's domain). -P 2: sish drops a connection idle for 5s (--idle-connection-timeout), and
# ttyd's default first ping comes only after 5s, so an idle page kept reconnecting to a new shell.
exec ttyd -i lo -p "$(codespace_port "$1")" -W -O -d 3 -P 2 -t "titleFixed=$title" -c "vscode:$token" "${cmd[@]}" > /dev/null 2>&1
CODESPACE_TTYD_EOF

sudo tee /usr/local/bin/dev > /dev/null <<'CODESPACE_DEV_EOF'
#!/usr/bin/env bash
# dev: check on and repair the codespace.
#   dev          make sure the codespace is up, show its status, open the `dev` tmux session
#   dev status   print status; exit 0 if healthy, 1 if not
#   dev logs     follow the codespace's logs (the `logs` window of the tmux session runs this)
#   dev reset    delete the codespace container and its home and /nix volumes, then create it again
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

row() { printf '  %-15s  %s\n' "$1" "$2"; }

# A browser shell's line. The shells don't need the container, and they're information only: they never
# make the codespace unhealthy.
shell_status() { # <id> <label>
    local unit="codespace-tunnel@$1"
    if [ ! -s "$CODESPACE_SHELL_TOKEN_FILE" ]; then
        row "$2" "off: $CODESPACE_SHELL_TOKEN_FILE is missing or empty"
    elif [ -z "$(codespace_tunnel_endpoint)" ]; then
        row "$2" "off: $CODESPACE_ENDPOINT_FILE is missing or empty"
    elif ! systemctl is-enabled --quiet "$unit.service"; then
        row "$2" "off: disabled (sudo systemctl enable --now $unit)"
    elif ! systemctl is-active --quiet "$unit.service"; then
        row "$2" "tunnel $(systemctl is-active "$unit.service" || true)  restarts=$(systemctl show -p NRestarts --value "$unit.service")  (sudo journalctl -u $unit -n 20)"
    elif ! systemctl is-active --quiet "codespace-ttyd@$1.service"; then
        row "$2" "ttyd $(systemctl is-active "codespace-ttyd@$1.service" || true)  (sudo journalctl -u codespace-ttyd@$1 -n 20)"
    else
        row "$2" "up  $(codespace_url "$1")  (open it from your Slack message's link; password in /etc/glueops/shell_token)"
    fi
}

shells_status() {
    shell_status shell "codespace shell"
    shell_status vm "vm shell"
}

# Prints one line per part and returns 0 only if the codespace is usable.
status() {
    local healthy=0 info state running started restarts oom code err image
    if ! info="$(docker container inspect -f '{{.State.Status}}|{{.State.Running}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.State.ExitCode}}|{{.Config.Image}}|{{.State.Error}}' "$CODESPACE_NAME" 2> /dev/null)"; then
        row container "missing - codespace-ensure creates it within a minute"
        row "" "(progress: sudo journalctl -u codespace-ensure -n 20)"
        shells_status
        return 1
    fi
    IFS='|' read -r state running started restarts oom code image err <<< "$info"
    local line="$state  ${image##*:}  restarts=$restarts"
    [ "$restarts" != 0 ] && line+="  last exit=$code"
    [ "$oom" = true ] && line+=" (OOM-killed)"
    row container "$line"
    [ -n "$err" ] && row "" "error: $err"
    if [ "$running" != true ] || [ "$state" = restarting ]; then
        healthy=1
        row "" "why: docker logs codespace    if it stays down: dev reset (deletes the container and its volumes)"
    fi

    case "$(codespace_mode)" in
        web)
            local http
            http="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8000/ || true)"
            if [ "$http" != 000 ] && [ -n "$http" ]; then
                row editor "up (127.0.0.1:8000)"
            else
                row editor "not answering on 127.0.0.1:8000  (docker logs codespace)"
                healthy=1
            fi
            if [ -z "$(codespace_tunnel_endpoint)" ]; then
                row sish "no endpoint: $CODESPACE_ENDPOINT_FILE is missing or empty"
                healthy=1
            else
                if systemctl is-active --quiet codespace-tunnel@editor.service; then
                    row sish "up  restarts=$(systemctl show -p NRestarts --value codespace-tunnel@editor.service)"
                else
                    row sish "$(systemctl is-active codespace-tunnel@editor.service || true)  restarts=$(systemctl show -p NRestarts --value codespace-tunnel@editor.service)  (sudo journalctl -u codespace-tunnel@editor -n 20)"
                    healthy=1
                fi
                row url "$(codespace_url editor)  (use your Slack link: it carries your token)"
            fi
            ;;
        tunnel)
            local js tstate tname devcode
            js="$(docker exec "$CODESPACE_NAME" /usr/share/code/bin/code-tunnel tunnel status 2> /dev/null || true)"
            tstate="$(jq -r '.tunnel.tunnel // empty' <<< "$js" 2> /dev/null || true)"
            tname="$(jq -r '.tunnel.name // empty' <<< "$js" 2> /dev/null || true)"
            if [ "$tstate" = Connected ]; then
                row editor "connected  https://vscode.dev/tunnel/$tname/workspaces/glueops"
            else
                healthy=1
                # It prints a fresh code on its own about every 15 minutes; only the latest one works.
                devcode="$(docker logs --since "$started" "$CODESPACE_NAME" 2>&1 | grep -o 'login/device and use code [A-Z0-9-]*' | tail -n1 | awk '{print $NF}' || true)"
                if [ -n "$devcode" ] && [ -z "$tname" ]; then
                    row editor "waiting for login: open https://github.com/login/device and enter $devcode"
                else
                    row editor "${tstate:-starting}  (dev logs)"
                fi
            fi
            [ -s "$CODESPACE_CDE_TOKEN_FILE" ] && row note "a connection token exists but the editor is a VS Code tunnel: dev reset"
            ;;
    esac
    shells_status
    row disk "$(df -h --output=avail / | tail -n1 | tr -d ' ') free on /"
    return "$healthy"
}

# Up to 30s for a codespace that is still starting. A tunnel waiting for its first login won't get
# healthy by waiting, so stop there and show the device code.
wait_healthy() {
    local out
    for _ in $(seq 1 30); do
        out="$(status)" && return 0
        grep -q 'waiting for login' <<< "$out" && return 1
        sleep 1
    done
    return 1
}

# Runs codespace-ensure now and waits for it, showing what it does: a first create can take minutes.
ensure_now() {
    local follower since from=(-n 0)
    # A run already in progress (e.g. the first boot's) logged its start before we got here; show it.
    if [ "$(systemctl show -p ActiveState --value codespace-ensure.service)" = activating ]; then
        since="$(systemctl show -p InactiveExitTimestamp --value codespace-ensure.service)"
        [ -n "$since" ] && from=(--since "$since")
    fi
    sudo journalctl -f "${from[@]}" -o cat -u codespace-ensure.service &
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
        row update "$latest is available (you have $current). Commit and push your work, then create a new codespace in Slack."
    fi
}

logs() {
    # In the tmux `logs` window, Ctrl-C must not close the window; anywhere else it stops dev logs. The
    # explicit exits are needed: docker logs exits cleanly on SIGINT, so bash wouldn't stop on its own,
    # and sudo's use_pty passes Ctrl-C only to journalctl, so bash never sees it.
    if [ -n "${DEV_LOGS_WINDOW:-}" ]; then
        trap 'echo; echo "(Ctrl-C does not stop anything here; detach from tmux with Ctrl-b d)"' INT
    else
        trap 'exit 130' INT
    fi
    local since="" last_start="" info running started
    while :; do
        case "$(codespace_mode)" in
            web)
                sudo journalctl -f -n 30 -u 'codespace-tunnel@*' -u 'codespace-ttyd@*' -u codespace-ensure.service || true
                [ -n "${DEV_LOGS_WINDOW:-}" ] || exit 130
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
                    sleep 5 || true
                fi
                ;;
            missing)
                echo "$(date +%T) no codespace container yet; codespace-ensure creates it"
                sleep 10 || true
                ;;
        esac
        sleep 2 || true
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
    gum confirm "Delete the codespace container AND its home and /nix volumes, then create it again? Anything not pushed is lost." || exit 1
    local tag=""
    [ "$ENVIRONMENT" = nonprod ] && tag="$(pick_tag)"
    # Stop the timer first so codespace-ensure can't recreate the container from the old tag midway.
    sudo systemctl stop codespace-ensure.timer
    # On exit, so a Ctrl-C during the (minutes-long) create doesn't leave the timer off until reboot. After
    # ensure_now: restarting the timer fires a run at once, before ensure_now could start watching it.
    trap 'sudo systemctl start codespace-ensure.timer' EXIT
    docker rm -f "$CODESPACE_NAME" > /dev/null 2>&1 || true
    docker volume rm codespace-home codespace-nix > /dev/null 2>&1 || true
    [ -n "$tag" ] && echo "$tag" | sudo tee "$CODESPACE_TAG_FILE" > /dev/null
    ensure_now
}

tmux_session() {
    # One chained command: if two `dev`s race, the second fails on "duplicate session" and adds nothing.
    tmux has-session -t =dev 2> /dev/null \
        || tmux new-session -d -s dev -n logs "dev status; DEV_LOGS_WINDOW=1 dev logs" \; new-window -d -t =dev -n shell \
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

sudo chmod 0755 /usr/local/bin/codespace-ensure /usr/local/bin/codespace-tunnel /usr/local/bin/codespace-ttyd /usr/local/bin/dev

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

sudo tee /etc/systemd/system/codespace-tunnel@.service > /dev/null <<'CODESPACE_TUNNEL_UNIT_EOF'
[Unit]
Description=sish reverse tunnel for the codespace %i
After=network-online.target cloud-final.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=vscode
# Skipped, not failed, while the tunnel's token or the endpoint is missing; checked on every restart.
ExecCondition=/usr/local/bin/codespace-tunnel --check %i
ExecStart=/usr/local/bin/codespace-tunnel %i
Restart=always
# Flat on purpose: RestartSteps never resets after a healthy run, so a stepped backoff ends up at
# its maximum for every later drop.
RestartSec=5s
# A reconnect doesn't pass through inactive, so it doesn't stop its codespace-ttyd (BindsTo).
RestartMode=direct
# A few MB of ssh carries everyone's access; let the kernel pick something else under memory pressure.
OOMScoreAdjust=-500

[Install]
WantedBy=cloud-init.target
CODESPACE_TUNNEL_UNIT_EOF

sudo tee /etc/systemd/system/codespace-ttyd@.service > /dev/null <<'CODESPACE_TTYD_UNIT_EOF'
[Unit]
Description=Browser shell %i (codespace-ttyd %i), served through codespace-tunnel@%i
BindsTo=codespace-tunnel@%i.service
After=codespace-tunnel@%i.service

[Service]
User=vscode
WorkingDirectory=~
Environment=LANG=C.UTF-8
ExecStart=/usr/local/bin/codespace-ttyd %i
# Stop only ttyd: a tmux server started in the VM shell also holds every other tmux session of vscode.
# Each browser shell still ends when its page disconnects.
KillMode=process
# The VM shells run in this unit: when one of them runs the VM out of memory, the kernel kills that
# process and the rest carry on. The default (stop) would also cut every other open shell.
OOMPolicy=continue
Restart=always
RestartSec=5s

[Install]
# Enable the instances (codespace-ttyd@shell, @vm), not the bare template.
WantedBy=codespace-tunnel@%i.service
CODESPACE_TTYD_UNIT_EOF

# Docker starts the container itself at boot; give tailscaled the chance to create its socket first.
sudo install -d -m 0755 /etc/systemd/system/docker.service.d /etc/systemd/system/tailscaled.service.d
printf '[Unit]\nAfter=tailscaled.service\n' | sudo tee /etc/systemd/system/docker.service.d/after-tailscaled.conf > /dev/null
# Keep /run/tailscale across tailscaled restarts (e.g. upgrades) so the container's bind of it stays valid.
printf '[Service]\nRuntimeDirectoryPreserve=yes\n' | sudo tee /etc/systemd/system/tailscaled.service.d/preserve-rundir.conf > /dev/null

sudo systemctl daemon-reload
# Enabled, not started: at image build there is no token or tag yet; the first boot starts them.
sudo systemctl enable codespace-ensure.service codespace-ensure.timer codespace-tunnel@editor.service codespace-tunnel@shell.service \
    codespace-tunnel@vm.service codespace-ttyd@shell.service codespace-ttyd@vm.service

# Fetch latest release if GLUEOPS_CODESPACES_CONTAINER_TAG is not set
if [ -z "$GLUEOPS_CODESPACES_CONTAINER_TAG" ]; then
  echo "GLUEOPS_CODESPACES_CONTAINER_TAG is not set. Fetching latest release..."
  GLUEOPS_CODESPACES_CONTAINER_TAG=$(curl -fsSL "https://api.github.com/repos/GlueOps/codespaces/releases/latest" | jq -r '.tag_name')

  if [ -z "$GLUEOPS_CODESPACES_CONTAINER_TAG" ] || [ "$GLUEOPS_CODESPACES_CONTAINER_TAG" == "null" ]; then
    echo "WARNING: Failed to fetch latest release tag. The codespace won't start until a tag is written to /etc/glueops/codespace-tag."
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



if [ -n "$GLUEOPS_CODESPACES_CONTAINER_TAG" ]; then
  echo "Pulling down codespace version: $GLUEOPS_CODESPACES_CONTAINER_TAG"
  until sudo docker pull ghcr.repo.gpkg.io/glueops/codespaces:$GLUEOPS_CODESPACES_CONTAINER_TAG; do echo "Docker pull failed, retrying in 20 seconds..."; sleep 20; done

  # Fill the codespace's home and /nix volumes now: Docker copies the image's content into a new volume
  # on first mount, which takes minutes and would otherwise hold up the codespace's first start.
  echo "Filling the codespace-home and codespace-nix volumes"
  sudo docker run --rm --entrypoint true -v codespace-home:/home/vscode -v codespace-nix:/nix \
      "ghcr.repo.gpkg.io/glueops/codespaces:$GLUEOPS_CODESPACES_CONTAINER_TAG"

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


