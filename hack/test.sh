#!/bin/bash
# Runs the captain_utils checks: syntax, shellcheck (when installed), and the stubbed harnesses. No cluster, no network.
set -e -u -o pipefail
cd "$(dirname "$0")/.."
TESTS=.devcontainer/tests/captain_utils
# helm is real in crds-terminating.sh: the shared helm stub prints "HELM ..." and dies in crds_fetch's document check.
for c in git yq jq helm; do command -v "$c" >/dev/null || { echo "hack/test.sh: $c is required" >&2; exit 1; }; done
echo "== bash -n"; bash -n .devcontainer/tools/captain_utils.sh .devcontainer/libexec/captain_utils/crds .devcontainer/libexec/captain_utils/custom.sh "$TESTS"/*.sh hack/test.sh
if command -v shellcheck >/dev/null; then
    echo "== shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
    shellcheck -S warning .devcontainer/libexec/captain_utils/crds .devcontainer/libexec/captain_utils/custom.sh "$TESTS"/*.sh
else
    echo "== shellcheck: not installed, skipped"
fi
for t in contract platform-custom crds-menu legacy-gate crds-cli crds-terminating; do
    echo "== $t"; bash "$TESTS/$t.sh" | grep -E '^#####|FAIL|assertions|command not found' | awk '{print} /^  FAIL|command not found/{bad=1} END{exit bad}'
done
# The cluster test is opt-in: it creates a kind cluster and takes minutes, while everything above is offline and
# finishes in seconds. CI runs it as its own job; locally, CRDS_TEST_KIND=1 hack/test.sh.
if [ "${CRDS_TEST_KIND:-0}" = 1 ]; then
    echo "== crds-kind"; bash "$TESTS/crds-kind.sh"
else
    echo "== crds-kind: skipped (set CRDS_TEST_KIND=1 to run; needs kind + a few minutes)"
fi
echo "ALL PASS"
