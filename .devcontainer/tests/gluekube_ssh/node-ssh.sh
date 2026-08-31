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
#   N3 guard both API-supplied addresses, which reach a shell via the ProxyCommand
#   N4 keep options before the destination and any remote command after it
#   N5 carry keepalives on BOTH hops
#   N6 actually be used by every call site (the helper being right is no use if
#      a raw `ssh -A` is reintroduced somewhere)
set -u -o pipefail
cd "$(dirname "$0")/../../.." || exit 1

TOOL=.devcontainer/tools/gluekube_ssh.sh
# shellcheck disable=SC1090  # non-constant source by design
source <(sed '$d' "$TOOL")
set +e  # the sourced file turns on -e; assertions must run even after failures

ARGS=$(mktemp); OUT=$(mktemp)
cleanup() { rm -f "$ARGS" "$OUT"; }
trap cleanup EXIT

gum() { echo "${@: -1}"; }
# Capture argv ONE PER LINE, not space-joined: joining loses argument
# boundaries, which is exactly what we need to assert (e.g. that the whole
# ProxyCommand is a single argument, and where the destination sits).
ssh() { printf '%s\n' "$@" > "$ARGS"; }

pass=0; fail=0
# NOTE the `--` in every grep: without it a pattern starting with `-` is parsed
# as an option, grep errors, and check_absent scores that non-match as a PASS -
# an assertion that can never fail.
check() { # <desc> <extended-regex> <file>
    if grep -qE -- "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (missing: $2)"; fi
}
check_absent() { # <desc> <extended-regex that must NOT appear> <file>
    if grep -qE -- "$2" "$3"; then fail=$((fail+1)); echo "  FAIL: $1 (unexpected: $2)"; else pass=$((pass+1)); fi
}
check_eq() { # <desc> <actual> <expected>
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi
}
# Line number of the first argv entry matching a regex (empty if none).
argline() { grep -nE -- "$2" "$1" | head -1 | cut -d: -f1; }

##### N1 no agent forwarding, no nested ssh #####
echo "##### N1 no agent forwarding, no nested ssh #####"
: > "$ARGS"
node_ssh 10.0.0.1 10.0.0.2 -- sudo cat /etc/kubernetes/admin.conf
check_absent "never forwards the agent (-A)" '^-A$' "$ARGS"
check "reaches the node directly"            '^cluster@10\.0\.0\.2$' "$ARGS"
check "remote command is passed through"     '^sudo$' "$ARGS"
# The bastion must never be handed an `ssh ...` command to run itself.
check_absent "no nested ssh command for the bastion" '^ssh ' "$ARGS"
# Ordering: the destination must come BEFORE the remote command, or ssh would
# treat the command as more options. (Swapping these passed the old suite.)
d=$(argline "$ARGS" '^cluster@10\.0\.0\.2$'); c=$(argline "$ARGS" '^sudo$')
if [[ -n "$d" && -n "$c" && "$d" -lt "$c" ]]; then pass=$((pass+1))
else fail=$((fail+1)); echo "  FAIL: destination must precede the remote command (dest=$d cmd=$c)"; fi

##### N2 bastion hop carries its own host-key options #####
echo "##### N2 bastion hop carries its own host-key options #####"
# One argv element must hold the entire ProxyCommand INCLUDING the options -
# the bastion hop is a separate ssh that inherits none of ours.
check "ProxyCommand is one arg carrying the bastion hop" \
    '^ProxyCommand=ssh .*-W %h:%p cluster@10\.0\.0\.1$' "$ARGS"
check "StrictHostKeyChecking inside the ProxyCommand" \
    '^ProxyCommand=ssh .*StrictHostKeyChecking=no.*-W %h:%p' "$ARGS"
check "UserKnownHostsFile inside the ProxyCommand" \
    '^ProxyCommand=ssh .*UserKnownHostsFile=/dev/null.*-W %h:%p' "$ARGS"
check_absent "does NOT use -o ProxyJump (child would not inherit opts)" 'ProxyJump' "$ARGS"

##### N3 API-supplied addresses are guarded #####
echo "##### N3 API-supplied addresses are guarded #####"
for bad_pos in bastion target; do
    : > "$ARGS"; : > "$OUT"
    if [[ "$bad_pos" == bastion ]]; then
        node_ssh 'evil$(id).example' 10.0.0.2 -- hostname > "$OUT" 2>&1
    else
        node_ssh 10.0.0.1 'evil$(id).example' -- hostname > "$OUT" 2>&1
    fi
    check_eq "refuses a metacharacter $bad_pos address (rc=1)" "$?" "1"
    check "says why ($bad_pos)" "contains unexpected characters - refusing" "$OUT"
    check_eq "and never invokes ssh ($bad_pos)" "$(wc -c < "$ARGS")" "0"
done
: > "$ARGS"
node_ssh bastion.example.com 10.0.0.2 -- hostname
check "accepts a DNS-name bastion" '^ProxyCommand=ssh .*cluster@bastion\.example\.com$' "$ARGS"

##### N4 option/command ordering, and the forward shape #####
echo "##### N4 options precede the destination, command follows #####"
: > "$ARGS"
node_ssh 10.0.0.1 10.0.0.2 -o ExitOnForwardFailure=yes -N -L 6443:localhost:6443
check "forward options passed through" '^-L$' "$ARGS"
check "local forward spec"             '^6443:localhost:6443$' "$ARGS"
check_eq "destination is the last arg" "$(tail -1 "$ARGS")" "cluster@10.0.0.2"
# The tunnel must terminate on the NODE. If the bastion were ever the ssh
# destination we would be back to forwarding a port ON it - the situation the
# old random mid-port workaround existed to survive.
check_absent "bastion is never the ssh destination" '^cluster@10\.0\.0\.1$' "$ARGS"
o=$(argline "$ARGS" '^-N$'); d=$(argline "$ARGS" '^cluster@10\.0\.0\.2$')
if [[ -n "$o" && -n "$d" && "$o" -lt "$d" ]]; then pass=$((pass+1))
else fail=$((fail+1)); echo "  FAIL: options must precede the destination (opt=$o dest=$d)"; fi
: > "$ARGS"
node_ssh 10.0.0.1 10.0.0.2 -t
check "interactive shell passes -t" '^-t$' "$ARGS"

##### N5 keepalives on both hops #####
echo "##### N5 keepalives on both hops #####"
check "keepalive on the node hop"    '^ServerAliveInterval=15$' "$ARGS"
check "keepalive inside the bastion hop" \
    '^ProxyCommand=ssh .*ServerAliveInterval=15.*-W %h:%p' "$ARGS"

##### N6 every call site actually uses the helper #####
echo "##### N6 every bastion hop goes through node_ssh #####"
# Guards against someone reintroducing a raw agent-forwarded hop at one site
# while the helper itself stays correct.
check_absent "no ssh -A anywhere in the tool" '^[^#]*ssh -A' "$TOOL"
check_absent "no nested ssh-in-a-string hop"  '^[^#]*"ssh -o' "$TOOL"
check_eq "all five bastion hops call node_ssh" \
    "$(grep -cE '^[^#]*node_ssh "\$bastion_ip"' "$TOOL")" "5"

echo "node-ssh.sh: $((pass + fail)) assertions, FAILS=$fail"
exit $(( fail > 0 ? 1 : 0 ))
