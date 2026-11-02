#!/bin/bash
# Runs the VM-side checks for developer-setup.sh: the scripts and systemd units it embeds as heredocs
# (codespace-ensure, codespace-tunnel, dev, and their units). Needs docker: everything runs inside a
# throwaway debian:13 container, the OS the VMs run, so the real systemd, cloud-init and sudo are used.
#   1. each embedded file is present and non-empty; bash -n and shellcheck on the scripts
#   2. systemd-analyze verify with cloud-init installed: no ordering cycle (the old launch-dev unit
#      must still produce one, proving the check works)
#   3. behaviour tests (tests/vm/cases.sh) with docker/systemctl/journalctl/curl/gum/tmux/ssh stubbed
set -e -u -o pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != --inside ]; then
    command -v docker > /dev/null || { echo "hack/test-codespace-vm.sh: docker is required" >&2; exit 1; }
    exec docker run --rm --hostname testvm -v "$PWD":/repo:ro -w /repo \
        debian:13@sha256:2dc419c6d7fe3dad0a2f9fd469c34cc90b0f9ba642d8fde837fe3d7d34a0e7f1 \
        bash hack/test-codespace-vm.sh --inside
fi

echo "== install test dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq > /dev/null
apt-get install -y -qq --no-install-recommends systemd cloud-init sudo jq bsdutils util-linux openssh-client shellcheck > /dev/null

# delimiter -> installed path, as developer-setup.sh writes them
files=(
    CODESPACE_COMMON_EOF:/usr/local/lib/codespace/common.sh
    CODESPACE_ENSURE_EOF:/usr/local/bin/codespace-ensure
    CODESPACE_TUNNEL_EOF:/usr/local/bin/codespace-tunnel
    CODESPACE_DEV_EOF:/usr/local/bin/dev
    CODESPACE_ENSURE_UNIT_EOF:/etc/systemd/system/codespace-ensure.service
    CODESPACE_ENSURE_TIMER_EOF:/etc/systemd/system/codespace-ensure.timer
    CODESPACE_TUNNEL_UNIT_EOF:/etc/systemd/system/codespace-tunnel.service
)
echo "== extract embedded files"
mkdir -p /usr/local/lib/codespace
for f in "${files[@]}"; do
    delim=${f%%:*} path=${f#*:}
    awk -v d="$delim" 'index($0, "<<'"'"'" d "'"'"'") {f=1; next} f && $0 == d {exit} f' developer-setup.sh > "$path"
    [ -s "$path" ] || { echo "  FAIL: $delim heredoc missing or empty in developer-setup.sh" >&2; exit 1; }
    echo "  $delim -> $path ($(wc -l < "$path") lines)"
done
chmod 755 /usr/local/bin/codespace-ensure /usr/local/bin/codespace-tunnel /usr/local/bin/dev

scripts=(/usr/local/lib/codespace/common.sh /usr/local/bin/codespace-ensure /usr/local/bin/codespace-tunnel /usr/local/bin/dev)
echo "== bash -n"; bash -n developer-setup.sh "${scripts[@]}" tests/vm/cases.sh tests/vm/stubs/* hack/test-codespace-vm.sh
echo "== shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
shellcheck -S warning -s bash "${scripts[@]}" tests/vm/cases.sh tests/vm/stubs/* hack/test-codespace-vm.sh

groupadd -f docker
useradd -m -u 1337 -G docker -s /bin/bash vscode
echo "vscode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vscode
mkdir -p /run/lock /workspaces

echo "== systemd-analyze verify"
# In a container cloud-init's generator never runs, so nothing pulls in cloud-init.target; on a VM
# it does. Link it in by hand or the units hung off it are never checked. verify exits 0 even when
# it finds a cycle, so the output is what's checked.
ln -sf /lib/systemd/system/cloud-init.target /etc/systemd/system/multi-user.target.wants/cloud-init.target
systemctl enable codespace-ensure.service codespace-ensure.timer codespace-tunnel.service 2> /dev/null
verify() { systemd-analyze verify --man=no default.target 2>&1 || true; }
out="$(verify)"
if grep -qi 'ordering cycle' <<< "$out"; then
    echo "  FAIL: ordering cycle:"; echo "$out" | sed 's/^/    /'; exit 1
fi
echo "  ok   no ordering cycle"
# Negative control: the launch-dev.service that shipped before these units.
printf '[Unit]\nAfter=network-online.target docker.service cloud-final.service\nWants=network-online.target cloud-final.service\n[Service]\nType=oneshot\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' \
    > /etc/systemd/system/launch-dev.service
systemctl enable launch-dev.service 2> /dev/null
if grep -qi 'ordering cycle' <<< "$(verify)"; then echo "  ok   old launch-dev.service still detected as a cycle"; else
    echo "  FAIL: the cycle check no longer detects the old launch-dev.service cycle" >&2; exit 1; fi
systemctl disable launch-dev.service 2> /dev/null; rm /etc/systemd/system/launch-dev.service

echo "== behaviour"
install -m 755 tests/vm/stubs/* /usr/local/bin/
bash tests/vm/cases.sh
echo "ALL PASS"
