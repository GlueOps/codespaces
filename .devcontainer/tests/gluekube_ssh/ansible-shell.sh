#!/bin/bash
# Opt-in integration test for gluekube_ssh's ansible shell (GLUEKUBE_TEST_DOCKER=1 hack/test-gluekube-ssh.sh).
# Boots the REAL pinned ansible image against a mock AutoGlue API and asserts the bootstrap
# contract: inventory groups/hostvars, ssh config + bastion multiplexing, key fetch into the
# tmpfs ~/.ssh with 0600, env scrubbing, the /work mount, and the .bashrc prompt/helpers.
# Needs docker; pulls the ~300MB image on first run.
set -u -o pipefail
cd "$(dirname "$0")/../../.." || exit 1
for c in docker jq python3; do command -v "$c" >/dev/null || { echo "ansible-shell.sh: $c is required" >&2; exit 1; }; done

PORT=18923
OUT=$(mktemp)
MOCK_LOG=$(mktemp)
cleanup() { [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null; rm -f "$OUT" "$MOCK_LOG"; }
trap cleanup EXIT

# --- mock AutoGlue API: the bootstrap only calls /ssh/{id}?reveal=true ---
python3 - "$PORT" >"$MOCK_LOG" 2>&1 <<'PYEOF' &
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        m = re.match(r"/api/v1/ssh/([\w-]+)\?reveal=true", self.path)
        body = json.dumps({"private_key": "-----BEGIN FAKE %s-----" % m.group(1)}) if m else "{}"
        print("REQ %s key=%s org=%s" % (self.path, self.headers.get("X-API-KEY"), self.headers.get("X-Org-ID")), flush=True)
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, *a): pass
HTTPServer(("0.0.0.0", int(sys.argv[1])), H).serve_forever()
PYEOF
MOCK_PID=$!
sleep 1

# The container runs on the host docker daemon; it reaches the mock via the bridge gateway.
GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 172.17.0.1)

# Source the tool without executing main (the file's last line), stub gum, and point libexec
# at the checkout: BASH_SOURCE resolves to /dev/fd when sourced, so the env override is the
# supported path for harnesses like this one.
# shellcheck disable=SC1090  # non-constant source by design
source <(sed '$d' .devcontainer/tools/gluekube_ssh.sh)
# The sourced file turns on `set -e`; turn it back off so a failing docker run
# aborts an assertion, not the harness - the report and output dump must always print.
set +e
gum() { echo "${@: -1}"; }
export GLUEKUBE_SSH_LIBEXEC="$PWD/.devcontainer/libexec/gluekube_ssh"
# shellcheck disable=SC2034  # read by the sourced ansible_shell_mode
API_ENDPOINT="http://$GW:$PORT/api/v1"
# shellcheck disable=SC2034
API_KEY="test-api-key"

# The null-hostname/null-role server is deliberate: mid-provision clusters
# carry them, and the inventory jq must filter them out instead of erroring.
cluster_json='{"bastion_server":{"hostname":"bastion","public_ip_address":"203.0.113.10","ssh_key_id":"key-bastion"},"node_pools":[{"servers":[{"role":"master","hostname":"master-1","status":"ready","private_ip_address":"10.0.0.11","ssh_key_id":"key-nodes"},{"role":"worker","hostname":"worker-1","status":"ready","private_ip_address":"10.0.0.21","ssh_key_id":"key-nodes"},{"role":null,"hostname":null,"status":"provisioning"}]}]}'

ansible_shell_mode "$cluster_json" "org-123" "nonprod.test.onglueops.com" >"$OUT" 2>&1 <<'CMDS'
ansible-inventory --graph 2>&1
ansible-inventory --host master-1
cat ~/.ssh/config
stat -c '%a %n' ~/.ssh/gluekube_* && cat ~/.ssh/gluekube_0
df ~/.ssh | tail -1
env | grep -q '^AUTOGLUE_API_KEY=' || echo "api key scrubbed"
pwd
bash -ic 'echo "PS1=$PS1"; type -t raw; type -t inv' 2>/dev/null
CMDS

pass=0; fail=0
check() { # <desc> <extended-regex expected in output>
    if grep -qE "$2" "$OUT"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (missing: $2)"; fi
}
check_absent() { # <desc> <extended-regex that must NOT appear>
    if grep -qE "$2" "$OUT"; then fail=$((fail+1)); echo "  FAIL: $1 (unexpected: $2)"; else pass=$((pass+1)); fi
}

check "banner names the cluster"       'GlueKube Ansible shell - nonprod\.test\.onglueops\.com'
check "graph has bastions group"       '@bastions:'
check "graph has masters group"        '@masters:'
check "graph has workers group"        '@workers:'
check "master uses private IP"         '"ansible_host": "10\.0\.0\.11"'
check "master jumps via bastion"       'ProxyJump=cluster@203\.0\.113\.10'
check "bastion hop is multiplexed"     'ControlMaster auto'
check "key files are 0600"             '600 .*gluekube_0'
check "key content came from the API"  'BEGIN FAKE key-bastion'
check "ssh dir is tmpfs"               '^tmpfs '
check "API key scrubbed from shell"    'api key scrubbed'
check "cwd is the /work mount"         '^/work$'
check "PS1 carries the cluster name"   'PS1=.*nonprod\.test\.onglueops\.com'
check "raw helper is a function"       '^function$'
check "inv helper is an alias"         '^alias$'
check_absent "no key-fetch warnings"   'WARNING: could not fetch'
check_absent "no group/host name clash" 'Found both group and host'

if ! grep -qE 'key=test-api-key org=org-123' "$MOCK_LOG"; then
    fail=$((fail+1)); echo "  FAIL: mock API never saw the expected auth headers"
else
    pass=$((pass+1))
fi
if [[ "$(grep -c IdentityFile "$OUT")" != "2" ]]; then
    fail=$((fail+1)); echo "  FAIL: expected exactly 2 IdentityFile lines in ssh config"
else
    pass=$((pass+1))
fi

echo "$((pass + fail)) assertions, $fail failures"
[[ $fail -eq 0 ]] || { echo "--- container output ---"; cat "$OUT"; exit 1; }
