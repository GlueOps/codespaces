#!/bin/bash
# Runs the captain_utils checks: syntax, shellcheck (when installed), and the stubbed harnesses. No cluster, no network.
set -e -u -o pipefail
cd "$(dirname "$0")/.."
TESTS=.devcontainer/tests/captain_utils
for c in git yq jq; do command -v "$c" >/dev/null || { echo "hack/test.sh: $c is required" >&2; exit 1; }; done
echo "== bash -n"; bash -n .devcontainer/tools/captain_utils.sh .devcontainer/libexec/captain_utils/crds .devcontainer/libexec/captain_utils/custom.sh "$TESTS"/*.sh hack/test.sh
if command -v shellcheck >/dev/null; then
    echo "== shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
    shellcheck -S warning .devcontainer/libexec/captain_utils/crds .devcontainer/libexec/captain_utils/custom.sh "$TESTS"/*.sh
else
    echo "== shellcheck: not installed, skipped"
fi
for t in contract platform-custom crds-menu legacy-gate crds-cli; do
    echo "== $t"; bash "$TESTS/$t.sh" | grep -E '^#####|FAIL|assertions|command not found' | awk '{print} /^  FAIL|command not found/{bad=1} END{exit bad}'
done
echo "ALL PASS"
