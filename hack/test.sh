#!/bin/bash
# Convenience wrapper: runs every app's checks. Each app has its own runner and its own CI workflow
# with per-app path triggers (only the shared Dockerfile triggers both) - use these directly when
# working on one app:
#   hack/test-captain-utils.sh   (captain_utils; CRDS_TEST_KIND=1 adds the kind cluster test)
#   hack/test-gluekube-ssh.sh    (gluekube_ssh; GLUEKUBE_TEST_DOCKER=1 adds the container test)
set -e -u -o pipefail
cd "$(dirname "$0")"
bash -n test.sh
echo "#### captain_utils ####"
./test-captain-utils.sh
echo "#### gluekube_ssh ####"
./test-gluekube-ssh.sh
