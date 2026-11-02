#!/usr/bin/env bash
# Behaviour tests for the VM-side scripts embedded in developer-setup.sh (codespace-ensure,
# codespace-tunnel, dev). Run by hack/test-codespace-vm.sh inside a throwaway debian:13 container,
# as root, after the scripts are installed at their real paths and tests/vm/stubs is on PATH ahead
# of the real tools. The stubs log every call to $STATE/calls; each case asserts on that log.
set -u -o pipefail
export STATE=/tmp/vmstate
TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fails=0
all_output=""

reset_state() {
    rm -rf "$STATE"
    mkdir -p "$STATE"
    chmod 777 "$STATE"
    : > "$STATE/calls"
    chmod 666 "$STATE/calls"
    mkdir -p /etc/glueops
    rm -f /etc/glueops/cde_token /etc/glueops/tunnel_endpoint
    echo v1 > /etc/glueops/codespace-tag
    : > /etc/glueops/codespace.env
}
token() { echo "$TOKEN" > /etc/glueops/cde_token; chmod 644 /etc/glueops/cde_token; }
state() { echo "$2" > "$STATE/$1"; chmod 666 "$STATE/$1"; }
# Runs a command, keeping its output in $out and its exit status in $rc.
run() { "$@" > /tmp/vm-out 2>&1; rc=$?; out="$(cat /tmp/vm-out)"; all_output+="$out"$'\n'; }
calls() { cat "$STATE/calls"; }
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect_call() { if calls | grep -qF -- "$2"; then pass "$1"; else fail "$1 (no call matching: $2)"; calls | sed 's/^/         /'; fi; }
expect_no_call() { if calls | grep -qF -- "$2"; then fail "$1 (unexpected call: $2)"; else pass "$1"; fi; }
expect_rc() { if [ "$rc" = "$2" ]; then pass "$1"; else fail "$1 (rc=$rc, want $2)"; fi; }

echo "== codespace-ensure"
reset_state; token
run codespace-ensure
expect_rc "missing container + token: exits 0" 0
for flag in "--restart unless-stopped" "-v /var/run/tailscale:/var/run/tailscale" "-v codespace-home:/home/vscode" \
    "-v codespace-nix:/nix" "-v /etc/glueops:/etc/glueops:ro" "ghcr.repo.gpkg.io/glueops/codespaces:v1"; do
    expect_call "  docker run has $flag" "$flag"
done
if grep -q -- '--host 127.0.0.1' "$STATE/cmd" && grep -q -- '--connection-token-file /etc/glueops/cde_token' "$STATE/cmd"; then
    pass "  token: main process is serve-web on 127.0.0.1 with the token file"
else fail "  token: main process is serve-web on 127.0.0.1 with the token file ($(cat "$STATE/cmd"))"; fi
expect_call "  runs cde-boot after create" "docker exec --env-file /etc/glueops/codespace.env codespace"
expect_call "  starts the tunnel when a token exists" "systemctl start --no-block codespace-tunnel.service"

reset_state
run codespace-ensure
if grep -q 'code-tunnel tunnel --random-name' "$STATE/cmd"; then pass "no token: main process is code tunnel"; else fail "no token: main process is code tunnel ($(cat "$STATE/cmd"))"; fi
expect_no_call "  no token: tunnel unit not started" "codespace-tunnel.service"

reset_state; token; state container running
run codespace-ensure
expect_no_call "running container: no start" "docker start"
expect_no_call "running container: no cde-boot" "docker exec"

reset_state; state container exited
run codespace-ensure
expect_call "exited container: started" "docker start codespace"
expect_call "exited container: cde-boot runs" "docker exec --env-file"
expect_no_call "exited container: not recreated" "docker run"

reset_state; : > /etc/glueops/codespace-tag
run codespace-ensure
expect_rc "empty tag: fails" 1
expect_no_call "  empty tag: no docker run" "docker run"

reset_state; state docker_down 1
run codespace-ensure
expect_rc "docker down: fails" 1
expect_no_call "  docker down: no create" "docker run"

echo "== codespace-tunnel"
reset_state; echo regional.example.com > /etc/glueops/tunnel_endpoint
rm -rf /home/vscode/.ssh
run su vscode -c codespace-tunnel
expect_call "regional endpoint: binds the hostname" "-l testvm -R testvm:80:localhost:8000 regional.example.com"
if [ -s /home/vscode/.ssh/sish_tunnel_key_id_ed25519 ]; then pass "  creates the key on first start"; else fail "  creates the key on first start"; fi
reset_state
run su vscode -c codespace-tunnel
expect_call "no endpoint file: legacy endpoint binds cde" "-l testvm -R cde:80:localhost:8000 tunnels.glueopshosted.com"

echo "== dev"
reset_state; token; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state tunnel_active 1
run dev < /dev/null
expect_call "no TTY (as root): re-runs as vscode" "[as vscode]"
expect_call "no TTY: starts ensure without blocking" "systemctl start --no-block codespace-ensure.service"
expect_no_call "no TTY: no tmux" "tmux"

reset_state; token; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state tunnel_active 1
run script -qec dev /dev/null
expect_call "TTY: blocking ensure start" "systemctl start codespace-ensure.service [as root]"
expect_call "TTY: creates the dev tmux session" "tmux new-session -d -s dev -n logs"
expect_call "TTY: attaches" "tmux attach -t =dev"

reset_state; token; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state tunnel_active 1
echo regional.example.com > /etc/glueops/tunnel_endpoint
run dev status
expect_rc "status, editor + tunnel up: healthy" 0
if grep -qF "https://testvm.regional.example.com" <<< "$out"; then pass "  prints the regional URL"; else fail "  prints the regional URL"; fi
state http 000
run dev status
expect_rc "status, editor not answering: unhealthy" 1
reset_state
run dev status
expect_rc "status, container missing: unhealthy" 1

reset_state; state container running; state cmd '["bash","-lc","exec code-tunnel tunnel --random-name"]'
state tunnel_status '{"tunnel":{"name":"testvm","tunnel":"Connected"}}'
run dev status
expect_rc "status, tunnel mode connected: healthy" 0
if grep -qF "https://vscode.dev/tunnel/testvm/workspaces/glueops" <<< "$out"; then pass "  prints the vscode.dev link"; else fail "  prints the vscode.dev link"; fi
state tunnel_status '{"tunnel":{"name":null,"tunnel":"Disconnected"}}'
printf 'To grant access to the server, please log into https://github.com/login/device and use code AAAA-1111\nTo grant access to the server, please log into https://github.com/login/device and use code BBBB-2222\n' > "$STATE/logs"
run dev status
expect_rc "status, tunnel mode waiting for login: unhealthy" 1
if grep -qF "BBBB-2222" <<< "$out" && ! grep -qF "AAAA-1111" <<< "$out"; then pass "  shows only the latest device code"; else fail "  shows only the latest device code"; fi

reset_state; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state tunnel_active 1; state gum_choice v8
ENVIRONMENT=nonprod run script -qec "dev reset" /dev/null
expect_call "reset: stops the ensure timer" "systemctl stop codespace-ensure.timer"
expect_call "  removes the container" "docker rm -f codespace"
expect_call "  removes both volumes" "docker volume rm codespace-home codespace-nix"
if [ "$(cat /etc/glueops/codespace-tag)" = v8 ]; then pass "  nonprod: writes the picked tag"; else fail "  nonprod: writes the picked tag ($(cat /etc/glueops/codespace-tag))"; fi
expect_call "  restarts the ensure timer" "systemctl start codespace-ensure.timer"

echo "== no output contains the token"
if grep -qF "$TOKEN" <<< "$all_output$(cat "$STATE/calls")"; then fail "token value found in output"; else pass "token never printed"; fi

[ "$fails" = 0 ] || { echo "$fails FAILED"; exit 1; }
