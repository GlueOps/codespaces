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

DOCKERLOG=$(mktemp); OUT=$(mktemp)
cleanup() { rm -f "$DOCKERLOG" "$OUT"; }
trap cleanup EXIT

gum() { echo "${@: -1}"; }
docker() { echo "docker $1" >> "$DOCKERLOG"; }

good_cluster() { # <bastion public_ip_address>
    printf '{"bastion_server":{"hostname":"bastion","public_ip_address":"%s","ssh_key_id":"k1"},"node_pools":[{"servers":[{"role":"master","hostname":"master-1","status":"ready","private_ip_address":"10.0.0.11","ssh_key_id":"k2"}]}]}' "$1"
}

pass=0; fail=0
check() { # <desc> <extended-regex expected in file> <file>
    if grep -qE "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (missing: $2)"; fi
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

echo "ansible-guards.sh: $((pass + fail)) assertions, FAILS=$fail"
exit $(( fail > 0 ? 1 : 0 ))
