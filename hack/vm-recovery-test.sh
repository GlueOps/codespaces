#!/bin/bash
# Recovery checks against a real codespace VM, for the release gate (README "QA / Testing"). Run it
# against a throwaway nonprod VM: it kills things, restarts docker and tailscaled, and reboots.
#   hack/vm-recovery-test.sh root@<vm>        (extra ssh options via SSH_OPTS, e.g. "-i key")
# Health is `dev status` on the VM, so it covers both the browser-editor and the code-tunnel mode.
set -u -o pipefail
target="${1:?usage: hack/vm-recovery-test.sh <ssh-target>}"
read -r -a ssh_opts <<< "${SSH_OPTS:-}"
on() { ssh -o BatchMode=yes -o ConnectTimeout=10 "${ssh_opts[@]}" "$target" "$1"; }
fails=0

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

on 'docker exec codespace pkill -9 -x code-tunnel'
wait_healthy "editor main process killed" 60

# Docker gives up on a container whose start fails; the per-minute codespace-ensure has to bring it back.
on 'docker update --restart=no codespace > /dev/null && docker kill codespace > /dev/null'
wait_healthy "container down with no restart policy" 150
on 'docker update --restart=unless-stopped codespace > /dev/null'

if [ "$mode" = web ]; then
    on 'pkill -9 -f "^ssh -N -T"'
    wait_healthy "tunnel ssh killed" 45
fi

on 'systemctl restart tailscaled'
if on 'sleep 3; docker exec codespace test -S /var/run/tailscale/tailscaled.sock'; then
    echo "  ok   tailscale socket visible in the container after a tailscaled restart"
else echo "  FAIL tailscale socket missing in the container after a tailscaled restart"; fails=$((fails + 1)); fi

before=$(on "docker container inspect -f '{{.State.StartedAt}}' codespace")
on 'systemctl restart docker'
wait_healthy "docker restarted" 60
if [ "$before" = "$(on "docker container inspect -f '{{.State.StartedAt}}' codespace")" ]; then
    echo "  ok   container kept running through the docker restart (live-restore)"
else echo "  FAIL container was restarted by the docker restart"; fails=$((fails + 1)); fi

if [ "$mode" = web ]; then
    # shellcheck disable=SC2016 # expanded on the VM
    leaks=$(on 'T=/etc/glueops/cde_token; n=0
        docker inspect codespace | grep -qFf $T && n=$((n+1))
        docker logs codespace 2>&1 | grep -qFf $T && n=$((n+1))
        journalctl -b --no-pager | grep -qFf $T && n=$((n+1))
        for p in /proc/[0-9]*; do [ "$p" = /proc/$$ ] && continue; grep -qaFf $T $p/cmdline 2> /dev/null && ! grep -qa grep $p/cmdline && n=$((n+1)); done
        echo $n')
    if [ "$leaks" = 0 ]; then echo "  ok   token not in docker inspect, docker logs, the journal or any command line"; else
        echo "  FAIL token found in $leaks places"; fails=$((fails + 1)); fi
fi

on 'systemctl reboot' 2> /dev/null
sleep 20
wait_healthy "reboot" 300

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
