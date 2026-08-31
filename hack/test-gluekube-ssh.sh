#!/bin/bash
# Runs the gluekube_ssh checks: bash syntax and the ansible-shell bootstrap's py_compile. No cluster, no network.
# The container integration test is opt-in (GLUEKUBE_TEST_DOCKER=1): it boots the real pinned ansible image
# against a mock AutoGlue API (needs docker + a ~300MB pull on first run). CI runs it as its own job.
set -e -u -o pipefail
cd "$(dirname "$0")/.."
for c in jq python3; do command -v "$c" >/dev/null || { echo "hack/test-gluekube-ssh.sh: $c is required" >&2; exit 1; }; done
echo "== bash -n"; bash -n .devcontainer/tools/gluekube_ssh.sh .devcontainer/tests/gluekube_ssh/*.sh hack/test-gluekube-ssh.sh
if command -v shellcheck >/dev/null; then
    echo "== shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
    shellcheck -S warning .devcontainer/tools/gluekube_ssh.sh .devcontainer/tests/gluekube_ssh/*.sh hack/test-gluekube-ssh.sh
else
    echo "== shellcheck: not installed, skipped"
fi
# ast.parse rather than py_compile: same syntax coverage, but writes no __pycache__ artifact
echo "== py_syntax"; python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' .devcontainer/libexec/gluekube_ssh/bootstrap.py
echo "== browse-fallback"; bash .devcontainer/tests/gluekube_ssh/browse-fallback.sh
echo "== ansible-guards"; bash .devcontainer/tests/gluekube_ssh/ansible-guards.sh
if [ "${GLUEKUBE_TEST_DOCKER:-0}" = 1 ]; then
    echo "== ansible-shell"; bash .devcontainer/tests/gluekube_ssh/ansible-shell.sh
else
    echo "== ansible-shell: skipped (set GLUEKUBE_TEST_DOCKER=1 to run; needs docker)"
fi
echo "ALL PASS"
