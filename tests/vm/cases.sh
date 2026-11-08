#!/usr/bin/env bash
# Behaviour tests for the VM-side scripts embedded in developer-setup.sh (codespace-ensure,
# codespace-tunnel, codespace-ttyd, dev). Run by hack/test-codespace-vm.sh inside a throwaway debian:13 container,
# as root, after the scripts are installed at their real paths and tests/vm/stubs is on PATH ahead
# of the real tools. The stubs log every call to $STATE/calls; each case asserts on that log.
set -u -o pipefail
export STATE=/tmp/vmstate
TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
TERMINAL_TOKEN="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fails=0
all_output=""

reset_state() {
    # Keep every case's calls for the final token check.
    [ -f "$STATE/calls" ] && all_output+="$(cat "$STATE/calls")"$'\n'
    rm -rf "$STATE"
    mkdir -p "$STATE"
    chmod 777 "$STATE"
    : > "$STATE/calls"
    chmod 666 "$STATE/calls"
    mkdir -p /etc/glueops
    rm -f /etc/glueops/cde_token /etc/glueops/terminal_token
    echo regional.example.com > /etc/glueops/tunnel_endpoint
    echo v1 > /etc/glueops/codespace-tag
    : > /etc/glueops/codespace.env
}
token() { echo "$TOKEN" > /etc/glueops/cde_token; chmod 644 /etc/glueops/cde_token; }
terminal_token() { echo "$TERMINAL_TOKEN" > /etc/glueops/terminal_token; chmod 644 /etc/glueops/terminal_token; }
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
    if grep -qF -- '--connection-token-file /etc/glueops/cde_token > /dev/null' "$STATE/cmd"; then pass "  serve-web stdout (it prints the token) is discarded"; else fail "  serve-web stdout (it prints the token) is discarded"; fi
else fail "  token: main process is serve-web on 127.0.0.1 with the token file ($(cat "$STATE/cmd"))"; fi
# Run the container's command for real against a fake home: it must pin the finished server, never a
# staging (unfinished) download, and pass no --commit-id when nothing is baked.
container_cmd="$(jq -r '.[2]' "$STATE/cmd")"
fake_home=/tmp/fake-home; sw=$fake_home/.vscode/cli/serve-web
rm -rf "$fake_home"; mkdir -p "$sw/aaa111/bin" "$sw/bbb222.staging-0f0f/bin" /usr/share/code/bin
printf '#!/bin/sh\necho "code-tunnel $*" >&2\n' > /usr/share/code/bin/code-tunnel  # stderr: stdout is discarded
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/cde-trust-serve-web
chmod +x /usr/share/code/bin/code-tunnel /usr/local/bin/cde-trust-serve-web
pinned="$(HOME=$fake_home bash -c "$container_cmd" 2>&1)"
if grep -qF -- "serve-web --commit-id aaa111 --disable-telemetry --host" <<< "$pinned"; then pass "  pins serve-web to the finished baked server, telemetry off"; else fail "  pins serve-web to the finished baked server, telemetry off ($pinned)"; fi
rm -rf "$sw/aaa111"
pinned="$(HOME=$fake_home bash -c "$container_cmd" 2>&1)"
if grep -q -- "--commit-id" <<< "$pinned"; then fail "  only a staging download: no --commit-id ($pinned)"; else pass "  only a staging download: no --commit-id"; fi
rm -rf "$fake_home" /usr/share/code /usr/local/bin/cde-trust-serve-web
expect_call "  runs cde-boot after create" "docker exec --env-file /etc/glueops/codespace.env codespace"
if grep -qF "CDE-BOOT-OUTPUT" <<< "$out"; then fail "  cde-boot output kept out of the journal"; else pass "  cde-boot output kept out of the journal"; fi
expect_call "  starts the editor tunnel when its token exists" "systemctl start --no-block codespace-tunnel@editor.service"
expect_no_call "  no terminal token: terminal tunnel not started" "codespace-tunnel@terminal.service [as root]"
if grep -q "first start" <<< "$out"; then fail "  volumes exist: no first-start note"; else pass "  volumes exist: no first-start note"; fi
reset_state; state no_volume 1
run codespace-ensure
if grep -q "first start: copying" <<< "$out"; then pass "  new volumes: says the first start takes minutes"; else fail "  new volumes: says the first start takes minutes"; fi

reset_state
run codespace-ensure
if grep -q 'code-tunnel tunnel --random-name' "$STATE/cmd"; then pass "no token: main process is code tunnel"; else fail "no token: main process is code tunnel ($(cat "$STATE/cmd"))"; fi
expect_no_call "  no token: no tunnel started" "systemctl start --no-block codespace-tunnel@"

reset_state; terminal_token
run codespace-ensure
expect_call "terminal token only: starts the terminal tunnel" "systemctl start --no-block codespace-tunnel@terminal.service"
expect_no_call "  and not the editor's" "systemctl start --no-block codespace-tunnel@editor.service"
reset_state; terminal_token; state disabled_codespace-tunnel@terminal 1
run codespace-ensure
expect_no_call "disabled terminal tunnel: stays off" "systemctl start --no-block codespace-tunnel@terminal.service"

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

reset_state; terminal_token; state docker_down 1
run codespace-ensure
expect_rc "docker down: fails" 1
expect_no_call "  docker down: no create" "docker run"
expect_call "  docker down: the terminal tunnel still starts" "systemctl start --no-block codespace-tunnel@terminal.service"

echo "== codespace-tunnel"
reset_state
rm -rf /home/vscode/.ssh
run su vscode -c "codespace-tunnel editor"
expect_call "editor: binds the hostname on the endpoint" "-l testvm -R testvm:80:localhost:8000 regional.example.com"
if [ -s /home/vscode/.ssh/sish_tunnel_key_id_ed25519 ]; then pass "  creates the key on first start"; else fail "  creates the key on first start"; fi
reset_state
run su vscode -c "codespace-tunnel terminal"
expect_call "terminal: binds term-<hostname>, same connection options" "-o IdentitiesOnly=yes -i /home/vscode/.ssh/sish_tunnel_key_id_ed25519 -p 2222 -l testvm -R term-testvm:80:localhost:7681 regional.example.com"
reset_state
run su vscode -c "codespace-tunnel bogus"
expect_rc "unknown tunnel: usage error" 2
expect_no_call "  no ssh" "ssh "
reset_state; rm /etc/glueops/tunnel_endpoint
run su vscode -c "codespace-tunnel editor"
expect_rc "no endpoint file: fails" 1
expect_no_call "  no endpoint file: no ssh" "ssh "
# The two tunnels start together at first boot: they must end up with one key, created once.
reset_state; rm -rf /home/vscode/.ssh
su vscode -c "codespace-tunnel editor" > /dev/null 2>&1 & su vscode -c "codespace-tunnel terminal" > /dev/null 2>&1 & wait
if [ "$(calls | grep -c '^ssh ')" = 2 ] && [ "$(ls /home/vscode/.ssh/sish_tunnel_key_id_ed25519* | wc -l)" = 2 ]; then
    pass "both at once: one key, both connect"; else fail "both at once: one key, both connect ($(calls | grep -c '^ssh ') ssh calls)"; fi

echo "== codespace-tunnel --check (the units' ExecCondition)"
check() { su vscode -c "codespace-tunnel --check $1" > /dev/null 2>&1; }
reset_state
if check editor || check terminal; then fail "no tokens: both skipped"; else pass "no tokens: both skipped"; fi
token
if check editor && ! check terminal; then pass "editor token: editor only"; else fail "editor token: editor only"; fi
terminal_token
if check terminal; then pass "terminal token: terminal runs"; else fail "terminal token: terminal runs"; fi
: > /etc/glueops/tunnel_endpoint
if check editor || check terminal; then fail "empty endpoint: both skipped"; else pass "empty endpoint: both skipped"; fi
if check bogus; then fail "unknown tunnel: skipped"; else pass "unknown tunnel: skipped"; fi
u=/etc/systemd/system/codespace-tunnel@.service
for line in "ExecCondition=/usr/local/bin/codespace-tunnel --check %i" "ExecStart=/usr/local/bin/codespace-tunnel %i" Restart=always RestartMode=direct WantedBy=cloud-init.target; do
    if grep -qxF "$line" $u; then pass "  template has $line"; else fail "  template has $line"; fi
done

echo "== codespace-ttyd"
reset_state; terminal_token
run su vscode -c codespace-ttyd
expect_call "login shell on loopback: writable, origin-checked, no notice logs, pings inside sish's idle timeout, user vscode" \
    "ttyd -i lo -p 7681 -W -O -d 3 -P 2 -t titleFixed=VM testvm -c REDACTED bash -l cred=ok [as vscode]"
reset_state; token
run su vscode -c codespace-ttyd
expect_rc "only the editor's token: fails" 1
expect_no_call "  no ttyd" "ttyd "
for bad in short "$(head -c 129 /dev/zero | tr '\0' a)" "$(printf 'a%.0s' $(seq 40))!"; do
    reset_state; printf '%s' "$bad" > /etc/glueops/terminal_token
    run su vscode -c codespace-ttyd
    expect_rc "malformed terminal token (${#bad} chars): fails" 1
    expect_no_call "  no ttyd" "ttyd "
done
if grep -q '^exec ttyd .* > /dev/null 2>&1$' /usr/local/bin/codespace-ttyd; then
    pass "  ttyd's output (its command line holds the token) is discarded"
else fail "  ttyd's output (its command line holds the token) is discarded"; fi
for line in User=vscode BindsTo=codespace-tunnel@terminal.service WantedBy=codespace-tunnel@terminal.service KillMode=process OOMPolicy=continue Restart=always; do
    if grep -qx "$line" /etc/systemd/system/codespace-ttyd.service; then pass "  unit has $line"; else fail "  unit has $line"; fi
done

echo "== dev"
reset_state; token; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state active_codespace-tunnel@editor 1
run dev < /dev/null
expect_call "no TTY (as root): re-runs as vscode" "[as vscode]"
expect_call "no TTY: starts ensure without blocking" "systemctl start --no-block codespace-ensure.service"
expect_no_call "no TTY: no tmux" "tmux"

reset_state; token; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state active_codespace-tunnel@editor 1
run script -qec dev /dev/null
expect_call "TTY: blocking ensure start" "systemctl start codespace-ensure.service [as root]"
expect_call "TTY: creates the dev tmux session" "tmux new-session -d -s dev -n logs dev status; DEV_LOGS_WINDOW=1 dev logs"
expect_call "TTY: attaches" "tmux attach -t =dev"
expect_call "  no run in progress: follows the journal from now" "journalctl -f -n 0 -o cat -u codespace-ensure.service"
reset_state; token; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state active_codespace-tunnel@editor 1; state ensure_running 1
run script -qec dev /dev/null
expect_call "TTY, run already in progress: shows it from its start" "journalctl -f --since Tue 2026-11-03 02:07:45 UTC -o cat -u codespace-ensure.service"

reset_state; token; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state active_codespace-tunnel@editor 1
run dev status
expect_rc "status, editor + tunnel up: healthy" 0
if grep -qF "https://testvm.regional.example.com" <<< "$out"; then pass "  prints the URL"; else fail "  prints the URL"; fi
if grep -qF "terminal   off: /etc/glueops/terminal_token is missing or empty" <<< "$out"; then pass "  no terminal token: says it's off, still healthy"; else fail "  no terminal token: says it's off, still healthy ($out)"; fi
terminal_token
run dev status
expect_rc "status, terminal tunnel down: still healthy" 0
if grep -qF "terminal   tunnel activating  restarts=0  (sudo journalctl -u codespace-tunnel@terminal -n 20)" <<< "$out"; then pass "  names the terminal tunnel"; else fail "  names the terminal tunnel ($out)"; fi
state disabled_codespace-tunnel@terminal 1
run dev status
if grep -qF "terminal   off: disabled (sudo systemctl enable --now codespace-tunnel@terminal)" <<< "$out"; then pass "  turned off: says so, not a fault"; else fail "  turned off: says so, not a fault ($out)"; fi
rm "$STATE/disabled_codespace-tunnel@terminal"
state active_codespace-tunnel@terminal 1
run dev status
if grep -qF "terminal   ttyd activating  (sudo journalctl -u codespace-ttyd -n 20)" <<< "$out"; then pass "  ttyd down: names ttyd"; else fail "  ttyd down: names ttyd ($out)"; fi
state active_codespace-ttyd 1
run dev status
expect_rc "status, terminal up: healthy" 0
if grep -qF "terminal   up  https://term-testvm.regional.example.com  (user vscode" <<< "$out"; then pass "  prints the terminal URL and user"; else fail "  prints the terminal URL and user ($out)"; fi
if grep -qF "$TERMINAL_TOKEN" <<< "$out"; then fail "  never prints the password"; else pass "  never prints the password"; fi
: > /etc/glueops/tunnel_endpoint
run dev status
expect_rc "status, empty endpoint file: unhealthy" 1
if grep -qF "sish       no endpoint" <<< "$out" && grep -qF "terminal   off: /etc/glueops/tunnel_endpoint" <<< "$out" && ! grep -qF "https://" <<< "$out"; then
    pass "  says so, prints no URLs"; else fail "  says so, prints no URLs ($out)"; fi
echo regional.example.com > /etc/glueops/tunnel_endpoint
state http 000
run dev status
expect_rc "status, editor not answering: unhealthy" 1
rm "$STATE/http" "$STATE/active_codespace-tunnel@editor"
run dev status
expect_rc "status, tunnel down: unhealthy" 1
reset_state; terminal_token; state active_codespace-tunnel@terminal 1; state active_codespace-ttyd 1
run dev status
expect_rc "status, container missing: unhealthy" 1
if grep -qF "terminal   up  https://term-testvm" <<< "$out"; then pass "  still shows the terminal (it's the way in)"; else fail "  still shows the terminal (it's the way in) ($out)"; fi

reset_state; state container running; state cmd '["bash","-lc","exec code-tunnel tunnel --random-name"]'
state tunnel_status '{"tunnel":{"name":"testvm","tunnel":"Connected"}}'
run dev status
expect_rc "status, tunnel mode connected: healthy" 0
if grep -qF "https://vscode.dev/tunnel/testvm/workspaces/glueops" <<< "$out"; then pass "  prints the vscode.dev link"; else fail "  prints the vscode.dev link"; fi
if grep -qF "terminal   off:" <<< "$out"; then pass "  shows the terminal line in tunnel mode too"; else fail "  shows the terminal line in tunnel mode too ($out)"; fi
state tunnel_status '{"tunnel":{"name":null,"tunnel":"Disconnected"}}'
printf 'To grant access to the server, please log into https://github.com/login/device and use code AAAA-1111\nTo grant access to the server, please log into https://github.com/login/device and use code BBBB-2222\n' > "$STATE/logs"
run dev status
expect_rc "status, tunnel mode waiting for login: unhealthy" 1
if grep -qF "BBBB-2222" <<< "$out" && ! grep -qF "AAAA-1111" <<< "$out"; then pass "  shows only the latest device code"; else fail "  shows only the latest device code"; fi

reset_state; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state active_codespace-tunnel@editor 1; state gum_choice v8
ENVIRONMENT=nonprod run script -qec "dev reset" /dev/null
expect_call "reset: stops the ensure timer" "systemctl stop codespace-ensure.timer"
expect_call "  removes the container" "docker rm -f codespace"
expect_call "  removes both volumes" "docker volume rm codespace-home codespace-nix"
if [ "$(cat /etc/glueops/codespace-tag)" = v8 ]; then pass "  nonprod: writes the picked tag"; else fail "  nonprod: writes the picked tag ($(cat /etc/glueops/codespace-tag))"; fi
expect_call "  restarts the ensure timer" "systemctl start codespace-ensure.timer"
ensure_line=$(calls | grep -nF "systemctl start codespace-ensure.service" | head -n1 | cut -d: -f1)
timer_line=$(calls | grep -nF "systemctl start codespace-ensure.timer" | head -n1 | cut -d: -f1)
if [ -n "$ensure_line" ] && [ "${timer_line:-0}" -gt "$ensure_line" ]; then pass "  restarts the timer after the ensure run"; else fail "  restarts the timer after the ensure run"; fi
reset_state; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state active_codespace-tunnel@editor 1; state kill_reset 1
run script -qec "dev reset" /dev/null
expect_call "reset killed during the create: still restarts the ensure timer" "systemctl start codespace-ensure.timer"

# journalctl returning stands in for Ctrl-C: under sudo's use_pty, dev itself never gets the SIGINT.
reset_state; token; state container running; state cmd '["bash","-lc","exec code-tunnel serve-web"]'; state active_codespace-tunnel@editor 1
run timeout 10 dev logs
expect_rc "logs, web mode, typed: stops when journalctl ends" 130
expect_call "  follows both tunnels and ttyd" "journalctl -f -n 30 -u codespace-tunnel@* -u codespace-ttyd.service -u codespace-ensure.service"
run timeout 5 sudo -u vscode env DEV_LOGS_WINDOW=1 dev logs
expect_rc "logs, web mode, tmux window: keeps following" 124

reset_state; state container running; state cmd '["bash","-lc","exec code-tunnel tunnel --random-name"]'
state tunnel_status '{"tunnel":{"name":null,"tunnel":"Disconnected"}}'
echo 'To grant access to the server, please log into https://github.com/login/device and use code CCCC-3333' > "$STATE/logs"
start=$SECONDS
run script -qec dev /dev/null
if [ $((SECONDS - start)) -lt 15 ]; then pass "TTY, waiting for login: shows the code without waiting for health"; else fail "TTY, waiting for login: took $((SECONDS - start))s"; fi
if grep -qF "CCCC-3333" <<< "$out"; then pass "  prints the device code"; else fail "  prints the device code"; fi

echo "== cde-trust-serve-web (the image's serve-web pre-bake)"
# serve-web extracts into "<hash>.staging-<uuid>" and renames it when done; a staging dir must never
# count as the server. The fake `code` stands in for that download: it creates the finished dir.
th=/tmp/trust-home; tsw=$th/.vscode/cli/serve-web
printf '#!/bin/sh\necho "$*" > /tmp/trust-code-args\necho "Web UI available at http://127.0.0.1:9"\nmkdir -p "$HOME/.vscode/cli/serve-web/ddd444/bin"\nprintf "#!/bin/sh\\n" > "$HOME/.vscode/cli/serve-web/ddd444/bin/code-server"\nexec sleep 30\n' > /usr/local/bin/code
chmod +x /usr/local/bin/code
shimmed() { grep -q 'cde-trust-serve-web shim' "$tsw/$1/bin/code-server"; }
rm -rf "$th"; mkdir -p "$tsw/aaa111/bin" "$tsw/bbb222.staging-0f0f/bin"
for d in aaa111 bbb222.staging-0f0f; do printf '#!/bin/sh\n' > "$tsw/$d/bin/code-server"; done
HOME=$th bash .devcontainer/tools/cde-trust-serve-web.sh > /dev/null 2>&1
if shimmed aaa111 && ! shimmed bbb222.staging-0f0f; then pass "finished server shimmed, staging download left alone"; else fail "finished server shimmed, staging download left alone"; fi
rm -rf "$th"; mkdir -p "$tsw/ccc333.staging-0f0f/bin" /usr/share/code/bin; printf '#!/bin/sh\n' > "$tsw/ccc333.staging-0f0f/bin/code-server"
printf '#!/bin/sh\necho "code 1.0.0 (commit ddd444)"\n' > /usr/share/code/bin/code-tunnel; chmod +x /usr/share/code/bin/code-tunnel
HOME=$th timeout 60 bash .devcontainer/tools/cde-trust-serve-web.sh > /dev/null 2>&1
if shimmed ddd444 && ! shimmed ccc333.staging-0f0f; then pass "only a staging download: waits for the finished server and shims it"; else fail "only a staging download: waits for the finished server and shims it"; fi
if grep -q -- "serve-web --commit-id ddd444 " /tmp/trust-code-args; then pass "  downloads the server for the installed CLI's commit"; else fail "  downloads the server for the installed CLI's commit ($(cat /tmp/trust-code-args))"; fi
rm -rf "$th" /usr/local/bin/code /usr/share/code /tmp/trust-code-args

echo "== no output contains the token"
# ttyd only ever prints the credential base64-encoded.
b64="$(printf 'vscode:%s' "$TERMINAL_TOKEN" | base64 -w0)"
everything="$all_output$(cat "$STATE/calls")"
if grep -qF -e "$TOKEN" -e "$TERMINAL_TOKEN" -e "$b64" <<< "$everything"; then fail "a token found in output"; else pass "tokens never printed, raw or base64"; fi

[ "$fails" = 0 ] || { echo "$fails FAILED"; exit 1; }
