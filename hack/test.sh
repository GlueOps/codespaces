#!/bin/bash
# Convenience wrapper: runs every app's checks. Each app has its own runner and its own CI workflow
# with per-app path triggers (only the shared Dockerfile triggers both) - use these directly when
# working on one app:
#   hack/test-captain-utils.sh   (captain_utils; CRDS_TEST_KIND=1 adds the kind cluster test)
#   hack/test-gluekube-ssh.sh    (gluekube_ssh; GLUEKUBE_TEST_DOCKER=1 adds the container test)
#   hack/test-app-chart-preflight.sh (app-chart-preflight)
#   hack/test-codespace-vm.sh    (developer-setup.sh's VM scripts and units; needs docker, so here it
#                                 only runs with CODESPACE_VM_TEST_DOCKER=1)
set -e -u -o pipefail
cd "$(dirname "$0")"
bash -n test.sh
echo "#### captain_utils ####"
./test-captain-utils.sh
echo "#### gluekube_ssh ####"
./test-gluekube-ssh.sh
echo "#### app-chart-preflight ####"
./test-app-chart-preflight.sh
echo "#### codespace VM ####"
if [ "${CODESPACE_VM_TEST_DOCKER:-0}" = 1 ]; then
    ./test-codespace-vm.sh
else
    echo "skipped (set CODESPACE_VM_TEST_DOCKER=1 to run; needs docker)"
fi
