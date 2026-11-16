#!/bin/bash
# Runs the app-chart-preflight checks: bash syntax, shellcheck (when installed) and the stubbed harness
# (stub kubectl and argocd; python3's http.server stands in for the local Argo CD server). No cluster, no network.
set -e -u -o pipefail
cd "$(dirname "$0")/.."
for c in jq yq python3 curl diff; do command -v "$c" >/dev/null || { echo "hack/test-app-chart-preflight.sh: $c is required" >&2; exit 1; }; done
echo "== bash -n"; bash -n .devcontainer/tools/app-chart-preflight.sh .devcontainer/tests/app-chart-preflight/*.sh hack/test-app-chart-preflight.sh
if command -v shellcheck >/dev/null; then
    echo "== shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
    shellcheck -S warning .devcontainer/tools/app-chart-preflight.sh .devcontainer/tests/app-chart-preflight/*.sh hack/test-app-chart-preflight.sh
else
    echo "== shellcheck: not installed, skipped"
fi
echo "== preflight"; bash .devcontainer/tests/app-chart-preflight/preflight.sh | grep -E '^#####|FAIL|assertions' | awk '{print} /^  FAIL/{bad=1} END{exit bad}'
echo "ALL PASS"
