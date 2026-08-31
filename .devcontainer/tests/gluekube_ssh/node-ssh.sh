#!/bin/bash
# Offline test for node_ssh, the single helper every bastion->node hop goes through.
#
# The property under test is not cosmetic: GlueOps bastions are hardened with
# `AllowAgentForwarding no`, so the old `ssh -A bastion "ssh node"` shape - which
# ran the second ssh ON the bastion and needed the forwarded agent - fails with
# "Permission denied (publickey)". node_ssh must therefore:
#   N1 never pass -A and never nest an ssh command on the bastion
#   N2 reach the node through a ProxyCommand, with the host-key options stated
#      explicitly for the BASTION hop (a -o ProxyJump= child does NOT inherit
#      the parent's command-line -o options, so it would fail host-key checking)
#   N3 guard the API-supplied bastion address, which lands in a shell-run string
#   N4 keep options before the destination and the remote command after it
set -u -o pipefail
cd "$(dirname "$0")/../../.." || exit 1

# shellcheck disable=SC1090  # non-constant source by design
source <(sed '$d' .devcontainer/tools/gluekube_ssh.sh)
set +e  # the sourced file turns on -e; assertions must run even after failures

ARGS=$(mktemp); OUT=$(mktemp)
cleanup() { rm -f "$ARGS" "$OUT"; }
trap cleanup EXIT

gum() { echo "${@: -1}"; }
# Capture the ssh command line instead of running it.
ssh() { printf '%s\n' "$*" > "$ARGS"; }

pass=0; fail=0
check() { # <desc> <extended-regex expected in file> <file>
    if grep -qE "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (missing: $2)"; fi
}
check_absent() { # <desc> <extended-regex that must NOT appear> <file>
    if grep -qE "$2" "$3"; then fail=$((fail+1)); echo "  FAIL: $1 (unexpected: $2)"; else pass=$((pass+1)); fi
}
check_eq() { # <desc> <actual> <expected>
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi
}

##### N1/N2 the shape of a plain remote command #####
echo "##### N1 no agent forwarding, no nested ssh #####"
: > "$ARGS"
node_ssh 10.0.0.1 10.0.0.2 -- sudo cat /etc/kubernetes/admin.conf
check_absent "never forwards the agent (-A)"        '(^| )-A( |$)' "$ARGS"
check_absent "no nested ssh command on the bastion" 'cluster@10\.0\.0\.1 +ssh ' "$ARGS"
check "reaches the node directly"                   'cluster@10\.0\.0\.2' "$ARGS"
check "remote command is passed through"            'sudo cat /etc/kubernetes/admin.conf' "$ARGS"

echo "##### N2 bastion hop carries its own host-key options #####"
check "uses a ProxyCommand for the bastion hop" 'ProxyCommand=ssh .* -W %h:%p cluster@10\.0\.0\.1' "$ARGS"
# The whole point: these must appear INSIDE the ProxyCommand, not only outside,
# because the bastion hop is a separate ssh that inherits no command-line opts.
check "StrictHostKeyChecking set for the bastion hop" \
    'ProxyCommand=ssh [^"]*StrictHostKeyChecking=no' "$ARGS"
check "UserKnownHostsFile set for the bastion hop" \
    'ProxyCommand=ssh [^"]*UserKnownHostsFile=/dev/null' "$ARGS"
check_absent "does NOT use -o ProxyJump (child would not inherit opts)" 'ProxyJump' "$ARGS"

##### N3 the address guard #####
echo "##### N3 API-supplied bastion address is guarded #####"
: > "$ARGS"; : > "$OUT"
node_ssh 'evil$(id).example' 10.0.0.2 -- hostname > "$OUT" 2>&1
check_eq "refuses a metacharacter address (rc=1)" "$?" "1"
check "says why"                                  "contains unexpected characters - refusing" "$OUT"
check_eq "and never invokes ssh"                  "$(wc -c < "$ARGS")" "0"
# A plain hostname must still be accepted - the guard allows letters/dots/dashes.
: > "$ARGS"
node_ssh bastion.example.com 10.0.0.2 -- hostname
check "accepts a DNS-name bastion" 'cluster@bastion\.example\.com' "$ARGS"

##### N4 option/command ordering, and the forward shape #####
echo "##### N4 options precede the destination, command follows #####"
: > "$ARGS"
node_ssh 10.0.0.1 10.0.0.2 -o ExitOnForwardFailure=yes -N -L 6443:localhost:6443
check "forward options present"    'ExitOnForwardFailure=yes .*-N .*-L 6443:localhost:6443' "$ARGS"
check "destination comes last"     'cluster@10\.0\.0\.2$' "$ARGS"
# The forward terminates on the NODE; nothing is bound on the bastion, which is
# why the old random mid-port workaround could be removed.
check_absent "no bastion-side mid-port forward" '-L [0-9]+:localhost:[0-9]+ .*cluster@10\.0\.0\.1' "$ARGS"
: > "$ARGS"
node_ssh 10.0.0.1 10.0.0.2 -t
check "interactive shell passes -t and no command" 'cluster@10\.0\.0\.2$' "$ARGS"
check "-t precedes the destination"                '(^| )-t .*cluster@10\.0\.0\.2' "$ARGS"

echo "node-ssh.sh: $((pass + fail)) assertions, FAILS=$fail"
exit $(( fail > 0 ? 1 : 0 ))
