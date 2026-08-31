#!/bin/bash
# Offline test for ansible_shell_mode's defense-in-depth input guards - these protect the
# generated ssh config and the in-container PS1 from API-supplied injection, so a silent
# regression of a guard must fail a test:
#   G1 bastion address with shell metacharacters is refused, and docker is never invoked
#   G2 cluster name with a single quote (the PS1 injection risk) is refused, no docker
#   G3 sane inputs pass both guards and reach docker run (stubbed)
set -u -o pipefail
cd "$(dirname "$0")/../../.." || exit 1

# Source the tool without executing main (the file's last line)
# shellcheck disable=SC1090  # non-constant source by design
source <(sed '$d' .devcontainer/tools/gluekube_ssh.sh)
set +e  # the sourced file turns on -e; assertions must run even after failures

# shellcheck disable=SC2034  # read by the sourced ansible_shell_mode
API_ENDPOINT="https://stub.invalid/api/v1"
# shellcheck disable=SC2034
API_KEY="stub"
export GLUEKUBE_SSH_LIBEXEC="$PWD/.devcontainer/libexec/gluekube_ssh"

DOCKERLOG=$(mktemp); OUT=$(mktemp); INVOUT=$(mktemp)
cleanup() { rm -f "$DOCKERLOG" "$OUT" "$INVOUT"; }
trap cleanup EXIT

gum() { echo "${@: -1}"; }
# Log the FULL argv (not just $1) so the generated inventory - passed as
# -e GLUEKUBE_INVENTORY_YML=<json> - can be asserted offline; the only other
# coverage of inventory content lives in the skippable docker integration test.
docker() {
    printf '%s\n' "docker $*" >> "$DOCKERLOG"
    # Also stash the generated inventory on its own so assertions can use jq
    # instead of grepping a multi-line argv blob.
    local a; for a in "$@"; do
        [[ "$a" == GLUEKUBE_INVENTORY_YML=* ]] && printf '%s' "${a#GLUEKUBE_INVENTORY_YML=}" > "$INVOUT"
    done
    return 0  # the loop's last test is usually false; don't leak that as a docker failure
}

good_cluster() { # <bastion public_ip_address>
    printf '{"bastion_server":{"hostname":"bastion","public_ip_address":"%s","ssh_key_id":"k1"},"node_pools":[{"servers":[{"role":"master","hostname":"master-1","status":"ready","private_ip_address":"10.0.0.11","ssh_key_id":"k2"}]}]}' "$1"
}

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

##### G1 bastion address with metacharacters: refused before docker #####
echo "##### G1 bastion address with metacharacters is refused #####"
: > "$DOCKERLOG"
ansible_shell_mode "$(good_cluster "203.0.113.10; rm -rf /")" org-1 "prod.acme" > "$OUT" 2>&1 </dev/null
check_eq "refused (rc=1)" "$?" "1"
check "refusal names the guard" "Bastion address .* contains unexpected characters - refusing" "$OUT"
check_eq "docker never invoked" "$(grep -c "docker run" "$DOCKERLOG")" "0"

##### G2 cluster name with a single quote: refused before docker #####
echo "##### G2 cluster name with a single quote is refused #####"
: > "$DOCKERLOG"
ansible_shell_mode "$(good_cluster "203.0.113.10")" org-1 "evil'\$(id).acme" > "$OUT" 2>&1 </dev/null
check_eq "refused (rc=1)" "$?" "1"
check "refusal names the guard" "Cluster name .* contains unexpected characters - refusing" "$OUT"
check_eq "docker never invoked" "$(grep -c "docker run" "$DOCKERLOG")" "0"

##### G3 sane inputs pass the guards and reach docker #####
echo "##### G3 sane inputs reach docker run #####"
: > "$DOCKERLOG"
ansible_shell_mode "$(good_cluster "203.0.113.10")" org-1 "prod.acme" > "$OUT" 2>&1 </dev/null
check_eq "succeeds (rc=0)" "$?" "0"
check "docker run invoked" "docker run" "$DOCKERLOG"
check "API key passed name-only (not in argv value)" "[-]e AUTOGLUE_API_KEY( |$)" "$DOCKERLOG"
check "tmpfs mount for ~/.ssh" "[-]-tmpfs /home/ansible/.ssh" "$DOCKERLOG"

##### G4 node inventory: injection IP dropped, groups + ProxyJump present #####
echo "##### G4 inventory content: injection dropped, groups intact #####"
: > "$DOCKERLOG"
# bastion + cluster name are clean (pass the guards); the WORKER carries a
# Jinja2-injection private_ip that the inventory jq must drop, while the real
# bastion (role-'bastion' node also present) must survive as its own group.
inj_cluster='{"bastion_server":{"hostname":"real-bastion","public_ip_address":"203.0.113.10","ssh_key_id":"k1"},"node_pools":[{"servers":[
  {"role":"master","hostname":"m1","status":"ready","private_ip_address":"10.0.0.11","ssh_key_id":"k2"},
  {"role":"worker","hostname":"evil","status":"ready","private_ip_address":"{{ lookup(1) }}","ssh_key_id":"k2"},
  {"role":"bastion","hostname":"fake-bastion","status":"ready","private_ip_address":"10.0.0.99","ssh_key_id":"k2"}]}]}'
ansible_shell_mode "$inj_cluster" org-1 "prod.acme" > "$OUT" 2>&1 </dev/null
check_eq "succeeds (rc=0)" "$?" "0"
check "masters group present" '"masters"' "$DOCKERLOG"
check "ProxyJump through the bastion set" "ProxyJump=cluster@203.0.113.10" "$DOCKERLOG"
# The bastion's OWN connection must be pinned to the shared control socket, or
# ansible's own -o ControlPath wins and it opens a fresh TCP connection every
# run - the one that gets refused by a per-source SSH rate limit.
check_eq "bastion group pinned to the shared control socket" \
    "$(jq -r '.all.children.bastions.vars.ansible_ssh_common_args // ""' "$INVOUT" | grep -c 'ControlPath=~/.ssh/cm-%C')" "1"
check_eq "node group keeps ProxyJump AND the shared socket" \
    "$(jq -r '.all.children.masters.vars.ansible_ssh_common_args // ""' "$INVOUT" | grep -c 'ProxyJump=cluster@203.0.113.10 -o ControlPath=~/.ssh/cm-%C')" "1"
check "bastion host passed to the bootstrap for pre-warming" "[-]e GLUEKUBE_BASTION_HOST" "$DOCKERLOG"
check "real bastion survives as a host" "real-bastion" "$DOCKERLOG"
check_absent "injection IP dropped from inventory" "lookup" "$DOCKERLOG"
check "role-bastion node kept in its own group" '"bastion_nodes"' "$DOCKERLOG"

##### G5 malformed/odd server data degrades gracefully, never wholesale #####
echo "##### G5 one bad server never kills the whole inventory #####"
: > "$DOCKERLOG"
# non-string IP (must drop only that server, not abort the jq), case-variant
# roles (must merge into one group, not silently lose a host), trailing-newline
# IP (must be rejected by the \z anchor), and a healthy master that must survive.
odd_cluster='{"bastion_server":{"hostname":"b","public_ip_address":"203.0.113.10","ssh_key_id":"k1"},"node_pools":[{"servers":[
  {"role":"master","hostname":"m1","status":"ready","private_ip_address":"10.0.0.11","ssh_key_id":"k2"},
  {"role":"worker","hostname":"numeric-ip","status":"ready","private_ip_address":12345,"ssh_key_id":"k2"},
  {"role":"worker","hostname":"w-lower","status":"ready","private_ip_address":"10.0.0.21","ssh_key_id":"k2"},
  {"role":"Worker","hostname":"w-upper","status":"ready","private_ip_address":"10.0.0.22","ssh_key_id":"k2"},
  {"role":"worker","hostname":"trailing-nl","status":"ready","private_ip_address":"10.0.0.23\n","ssh_key_id":"k2"}]}]}'
ansible_shell_mode "$odd_cluster" org-1 "prod.acme" > "$OUT" 2>&1 </dev/null
check_eq "succeeds despite bad rows (rc=0)" "$?" "0"
check "healthy master survived" "m1" "$DOCKERLOG"
check "case-variant worker kept (roles merged)" "w-upper" "$DOCKERLOG"
check "lower-case worker kept" "w-lower" "$DOCKERLOG"
check_absent "non-string IP server dropped" "numeric-ip" "$DOCKERLOG"
check_absent "trailing-newline IP server dropped" "trailing-nl" "$DOCKERLOG"

echo "ansible-guards.sh: $((pass + fail)) assertions, FAILS=$fail"
exit $(( fail > 0 ? 1 : 0 ))
