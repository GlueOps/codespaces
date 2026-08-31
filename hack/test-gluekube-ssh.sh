#!/bin/bash
# Runs the gluekube_ssh checks: bash syntax, shellcheck, the bootstrap's python syntax (ast.parse), and the
# offline browse-fallback + ansible-guards harnesses. No cluster, no network.
# The container integration test is opt-in (GLUEKUBE_TEST_DOCKER=1): it boots the real pinned ansible image
# against a mock AutoGlue API (needs docker + a ~300MB pull on first run). CI runs it as its own job.
set -e -u -o pipefail
cd "$(dirname "$0")/.."
for c in jq python3; do command -v "$c" >/dev/null || { echo "hack/test-gluekube-ssh.sh: $c is required" >&2; exit 1; }; done
echo "== bash -n"; bash -n .devcontainer/tools/gluekube_ssh.sh .devcontainer/tests/gluekube_ssh/*.sh \
    hack/test-gluekube-ssh.sh hack/test.sh developer-setup.sh
if command -v shellcheck >/dev/null; then
    echo "== shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
    shellcheck -S warning .devcontainer/tools/gluekube_ssh.sh .devcontainer/tests/gluekube_ssh/*.sh hack/test-gluekube-ssh.sh
else
    echo "== shellcheck: not installed, skipped"
fi
# The golden-image pre-warm (developer-setup.sh) scrapes the ANSIBLE_IMAGE pin
# out of the tool with this exact sed; assert the contract so a reformat of that
# line can't silently ship VMs with no pre-warmed image (only surfaces post-merge).
echo "== prewarm-contract"
prewarm_ref=$(sed -n 's/^ANSIBLE_IMAGE="\(.*\)"$/\1/p' .devcontainer/tools/gluekube_ssh.sh)
if [ -z "$prewarm_ref" ]; then
    echo "  FAIL: developer-setup.sh's ANSIBLE_IMAGE sed matched nothing - the pin format changed" >&2
    exit 1
fi
# All three harnesses source the tool via  source <(sed '$d' gluekube_ssh.sh)  to
# get its functions without running main. That only holds while `main "$@"` is the
# LAST line; enforce it so an appended line can't make every harness execute main.
echo "== main-last-line"
if [ "$(tail -n1 .devcontainer/tools/gluekube_ssh.sh)" != 'main "$@"' ]; then
    echo "  FAIL: gluekube_ssh.sh's last line is not 'main \"\$@\"' - the sed-source harnesses will run main" >&2
    exit 1
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
