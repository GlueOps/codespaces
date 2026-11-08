#!/bin/bash
# Recovery checks against a real codespace VM, for the release gate (README "QA / Testing"). Run it
# against a throwaway nonprod VM: it kills things, restarts docker and tailscaled, and reboots.
#   hack/vm-recovery-test.sh root@<vm>        (extra ssh options via SSH_OPTS, e.g. "-i key")
# Health is `dev status` on the VM, so it covers both the browser-editor and the code-tunnel mode.
set -u -o pipefail
target="${1:?usage: hack/vm-recovery-test.sh <ssh-target>}"
read -r -a ssh_opts <<< "${SSH_OPTS:-}"
# No ssh host-key checking: the reboot test compares the VM's host keys itself, and a changed key would otherwise
# make every later ssh fail and the run hang until its time limit.
on() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${ssh_opts[@]}" "$target" "$1"; }
fails=0
started() { on "docker container inspect -f '{{.State.StartedAt}}' codespace"; }
# A fault that didn't happen would pass as "healthy after 0s"; each check then confirms its fault happened.
changed() { # <label> <before> <after>
    if [ "$2" != "$3" ]; then return 0; fi
    echo "  FAIL $1: the fault didn't take effect"; fails=$((fails + 1)); return 1
}

wait_healthy() { # <label> <seconds>
    local start=$SECONDS
    while [ $((SECONDS - start)) -lt "$2" ]; do
        if on 'dev status' > /dev/null 2>&1; then echo "  ok   $1: healthy after $((SECONDS - start))s"; return 0; fi
        sleep 3
    done
    echo "  FAIL $1: not healthy after $2s"; on 'dev status' | sed 's/^/       /'
    fails=$((fails + 1))
}

mode=$(on "docker container inspect -f '{{json .Config.Cmd}}' codespace" | grep -q serve-web && echo web || echo tunnel)
echo "== $target (mode: $mode)"
wait_healthy "baseline" 60

before=$(started)
on 'docker exec codespace pkill -9 -x code-tunnel'
wait_healthy "editor main process killed" 60
changed "editor main process killed" "$before" "$(started)"

# Docker gives up on a container whose start fails; the per-minute codespace-ensure has to bring it back.
before=$(started)
on 'docker update --restart=no codespace > /dev/null && docker kill codespace > /dev/null'
wait_healthy "container down with no restart policy" 150
changed "container down with no restart policy" "$before" "$(started)"
on 'docker update --restart=unless-stopped codespace > /dev/null'

# Each sish tunnel on its own: killing one must bring it back without touching the other one or ttyd.
nrestarts() { on "systemctl show -p NRestarts --value codespace-tunnel@$1"; }
ttyd_pid() { on 'systemctl show -p MainPID --value codespace-ttyd'; }
# One unit per is-active: with several, it succeeds when any one of them is active.
terminal_up() { # <label>
    on 'test -s /etc/glueops/terminal_token' || return 0
    if on 'systemctl is-active --quiet codespace-tunnel@terminal && systemctl is-active --quiet codespace-ttyd'; then
        echo "  ok   VM terminal up $1"
    else echo "  FAIL VM terminal not up $1 (dev status)"; fails=$((fails + 1)); fi
}
terminal_up "at the start"
for t in editor terminal; do
    on "systemctl is-active --quiet codespace-tunnel@$t" || continue
    other=terminal; [ "$t" = terminal ] && other=editor
    before=$(nrestarts "$t"); before_other=$(nrestarts "$other"); pid=$(ttyd_pid)
    on "systemctl kill -s KILL --kill-whom=main codespace-tunnel@$t"
    back=0
    for _ in $(seq 1 15); do
        sleep 3
        [ "$(nrestarts "$t")" != "$before" ] && on "systemctl is-active --quiet codespace-tunnel@$t" && { back=1; break; }
    done
    if [ "$back" = 1 ]; then
        echo "  ok   $t tunnel reconnected"
    else echo "  FAIL $t tunnel not back after its ssh was killed"; fails=$((fails + 1)); fi
    if [ "$before_other" = "$(nrestarts "$other")" ] && [ "$pid" = "$(ttyd_pid)" ]; then
        echo "  ok   $other tunnel and ttyd untouched"
    else echo "  FAIL killing the $t tunnel restarted the $other tunnel or ttyd"; fails=$((fails + 1)); fi
done
wait_healthy "tunnels killed" 45

on 'systemctl restart tailscaled'
if on 'sleep 3; docker exec codespace test -S /var/run/tailscale/tailscaled.sock'; then
    echo "  ok   tailscale socket visible in the container after a tailscaled restart"
else echo "  FAIL tailscale socket missing in the container after a tailscaled restart"; fails=$((fails + 1)); fi

before=$(started)
on 'systemctl restart docker'
wait_healthy "docker restarted" 60
if [ "$before" = "$(started)" ]; then
    echo "  ok   container kept running through the docker restart (live-restore)"
else echo "  FAIL container was restarted by the docker restart"; fails=$((fails + 1)); fi

# shellcheck disable=SC2016 # expanded on the VM
# The patterns: each token, and the base64 of vscode:<terminal token> that ttyd prints. ttyd's own
# command line holds the terminal token by design (it has no credential-file option); -o json includes
# the _CMDLINE journald stores with each line. An empty pattern would match everything, so only tokens
# that exist are added.
leaks=$(on 'P=$(mktemp); n=0; c=$(cat /etc/glueops/cde_token 2> /dev/null); t=$(cat /etc/glueops/terminal_token 2> /dev/null)
    { [ -n "$c" ] && printf "%s\n" "$c"; [ -n "$t" ] && { printf "%s\n" "$t"; printf "vscode:%s" "$t" | base64 -w0; echo; }; } > $P
    if [ -s $P ]; then
        docker inspect codespace | grep -qFf $P && n=$((n+1))
        docker logs codespace 2>&1 | grep -qFf $P && n=$((n+1))
        journalctl -b -o json --no-pager | grep -qFf $P && n=$((n+1))
        for p in /proc/[0-9]*; do [ "$p" = /proc/$$ ] && continue; [ "$(cat $p/comm 2> /dev/null)" = ttyd ] && continue
            grep -qaFf $P $p/cmdline 2> /dev/null && ! grep -qa grep $p/cmdline && n=$((n+1)); done
    fi
    rm -f $P; echo $n')
if [ "$leaks" = 0 ]; then echo "  ok   tokens not in docker inspect, docker logs, the journal or any command line but ttyd's"; else
    echo "  FAIL a token found in $leaks places"; fails=$((fails + 1)); fi

boot=$(on 'cat /proc/sys/kernel/random/boot_id')
hostkeys=$(on 'cat /etc/ssh/ssh_host_*_key.pub | sort')
on 'systemctl reboot' 2> /dev/null
sleep 20
until on true 2> /dev/null && [ "$(on 'cat /proc/sys/kernel/random/boot_id')" != "$boot" ]; do
    [ $SECONDS -gt 3600 ] && break
    sleep 5
done
wait_healthy "reboot" 300
changed "reboot" "$boot" "$(on 'cat /proc/sys/kernel/random/boot_id')"
if [ "$hostkeys" = "$(on 'cat /etc/ssh/ssh_host_*_key.pub | sort')" ]; then
    echo "  ok   SSH host keys unchanged by the reboot"
else
    echo "  FAIL SSH host keys changed on reboot (cloud-init treated the VM as new)"; fails=$((fails + 1))
fi
terminal_up "after the reboot"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
