#!/bin/bash
# The one claim stubs cannot make: a real finalizer pins a CRD in Terminating, the command refuses to apply, and the
# CRD survives WITH ITS FINALIZERS INTACT. That last assertion is the anti-`kubectl replace` proof — replace issues a
# whole-object PUT, which erased metadata.finalizers and destroyed the terminating CRD outright, orphaning its objects.
#
# Opt-in: CRDS_TEST_KIND=1 hack/test.sh, or run this file directly. Creates and destroys its own kind cluster and its
# own kubeconfig; it never reads or writes ~/.kube/config and never touches a cluster it did not create.
set -e -u -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(git -C "$HERE" rev-parse --show-toplevel)
CRDS=$REPO/.devcontainer/libexec/captain_utils/crds
for c in kind kubectl helm jq yq gum; do command -v "$c" >/dev/null || { echo "crds-kind.sh: $c is required" >&2; exit 1; }; done

CLUSTER=crds-kind-test-$$
T=$(mktemp -d)
export KUBECONFIG="$T/kubeconfig"          # set BEFORE the cluster exists: nothing here can reach another cluster
cleanup() { kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$T"; }
trap cleanup EXIT
FAILS=0; CASES=0
expect() { CASES=$((CASES+1)); if grep -q -- "$1" "$T/out"; then echo "  ok: $1"; else echo "  FAIL: missing '$1'"; FAILS=$((FAILS+1)); fi; }
refute() { CASES=$((CASES+1)); if grep -q -- "$1" "$T/out"; then echo "  FAIL: unexpected '$1'"; FAILS=$((FAILS+1)); else echo "  ok: no '$1'"; fi; }
ok()     { CASES=$((CASES+1)); if "${@:2}"; then echo "  ok: $1"; else echo "  FAIL: $1"; FAILS=$((FAILS+1)); fi; }

# ---- fixture bundle ----
mkdir -p "$T/bundle/crds" "$T/work"
printf 'apiVersion: v2\nname: platform-crds\nversion: 0.0.0\n' > "$T/bundle/Chart.yaml"
cat > "$T/bundle/crds/widgets.test.glueops.dev.yaml" <<'Y'
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.test.glueops.dev
spec:
  group: test.glueops.dev
  scope: Namespaced
  names: { plural: widgets, singular: widget, kind: Widget, listKind: WidgetList }
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties: { spec: { type: object } }
Y

echo "##### creating kind cluster $CLUSTER #####"
# CI pins the node image to the fleet's Kubernetes version; locally the kind default is fine. The cluster is always
# created and destroyed here rather than reused, so the script can never act on a cluster it does not own.
kind create cluster --name "$CLUSTER" ${CRDS_KIND_NODE_IMAGE:+--image "$CRDS_KIND_NODE_IMAGE"} --wait 90s >/dev/null

run() { ( cd "$T/work" && environment=dev CRDS_AUTO_CONFIRM=yes CRDS_WAIT_TIMEOUT=15s \
            "$CRDS" apply-dir "$T/bundle"; echo "RC=$?" ) > "$T/out" 2>&1 || echo "RC=$?" >> "$T/out"; cat "$T/out"; }

checkdir() { ( cd "$T/work" && environment=dev "$CRDS" check-dir "$T/bundle"; echo "RC=$?" ) > "$T/out" 2>&1 || echo "RC=$?" >> "$T/out"; cat "$T/out"; }

echo "##### A0. check on an empty cluster: reports drift, changes nothing #####"
checkdir
expect "RC=1"
expect "drift: this cluster does not match"
ok "check created no CRD" bash -c '! kubectl get crd widgets.test.glueops.dev >/dev/null 2>&1'

echo "##### A. healthy cluster: the bundle applies and takes ownership #####"
run
expect "RC=0"
ok "CRD is Established" kubectl wait --for=condition=Established crd/widgets.test.glueops.dev --timeout=30s
ok "owned by glueops-platform-crds" bash -c '
  kubectl get crd widgets.test.glueops.dev --show-managed-fields -o json \
    | jq -e ".metadata.managedFields[] | select(.manager==\"glueops-platform-crds\" and .operation==\"Apply\")" >/dev/null'

echo "##### A1. check after the apply: in sync #####"
checkdir
expect "RC=0"
expect "in sync with platform-crds"
expect "all 1 owned by glueops-platform-crds"

echo "##### B. a finalizer holds the CRD in Terminating: the apply is refused #####"
kubectl apply -f - >/dev/null <<'W'
apiVersion: test.glueops.dev/v1
kind: Widget
metadata:
  name: pinned
  namespace: default
  finalizers: ["test.glueops.dev/hold"]
spec: {}
W
kubectl delete crd widgets.test.glueops.dev --wait=false >/dev/null
# the CRD is now Terminating and cannot complete: customresourcecleanup blocks on the finalizer-held Widget
kubectl get crd widgets.test.glueops.dev -o jsonpath='{.metadata.deletionTimestamp}' | grep -q . \
  || { echo "  FAIL: fixture did not reach Terminating" >&2; exit 1; }
run
expect "still terminating after 15s"
expect "the bundle was NOT applied"
refute "✅"
expect "RC=1"

# The regression itself: the CRD must still be there, still holding its finalizer. `kubectl replace` erased exactly
# this, which is why it destroyed a terminating CRD and orphaned every object of the type.
ok "terminating CRD still exists" kubectl get crd widgets.test.glueops.dev
ok "its finalizers were NOT erased" bash -c '
  [ "$(kubectl get crd widgets.test.glueops.dev -o jsonpath="{.metadata.finalizers[0]}")" = "customresourcecleanup.apiextensions.k8s.io" ]'
ok "the Widget was not orphaned" kubectl get widget pinned -n default

kubectl patch widget pinned -n default --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
echo; echo "$(basename "$0"): $CASES assertions, FAILS=$FAILS"; [ "$FAILS" -eq 0 ]
