#!/bin/bash
# The property the two deleted text guards were approximating: a CRD that is being deleted MUST block the apply.
# Behavioural, not textual — this fails if the guard is deleted, gutted, reordered after the apply, or stops working
# for a reason nobody predicted. No cluster, no network: kubectl is a stub state machine, helm is REAL (the shared
# helm stub in stubs.sh prints "HELM ..." and would die in crds_fetch's document-count check), and the bundle is a
# local fixture reached through `apply-dir`, which needs no registry.
#
# What a cluster is still needed for (see crds-kind.sh): that a finalizer genuinely pins the CRD, and that
# server-side apply preserves metadata.finalizers where `kubectl replace` erased them.
set -e -u -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(git -C "$HERE" rev-parse --show-toplevel)
CRDS=$REPO/.devcontainer/libexec/captain_utils/crds
command -v helm >/dev/null || { echo "crds-terminating.sh: helm is required (real, not stubbed)" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0; CASES=0
expect() { CASES=$((CASES+1)); if grep -q -- "$1" "$T/out"; then echo "  ok: $1"; else echo "  FAIL: missing '$1'"; FAILS=$((FAILS+1)); fi; }
refute() { CASES=$((CASES+1)); if grep -q -- "$1" "$T/out"; then echo "  FAIL: unexpected '$1'"; FAILS=$((FAILS+1)); else echo "  ok: no '$1'"; fi; }

# ---- fixture bundle: a rendered platform-crds checkout, one CRD, leading --- as helm requires ----
mkdir -p "$T/bundle/crds" "$T/work" "$T/bin"
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
  names: { plural: widgets, singular: widget, kind: Widget }
  versions:
    - name: v1
      served: true
      storage: true
      schema: { openAPIV3Schema: { type: object } }
Y

# ---- stubs: gum passes text through; kubectl is a state machine over `get crd` invocations ----
cat > "$T/bin/gum" <<'G'
#!/bin/bash
case "$1" in
  style) shift; while [ $# -gt 0 ] && [[ "$1" == --* ]]; do [ "$1" = "--foreground" ] && shift; shift; done; echo "GUM: $*";;
  confirm) exit 0;; pager) cat;; *) :;;
esac
G
# GET_TERMINATING_FROM=N: the Nth and later `kubectl get crd` calls report a deletionTimestamp. The command reads live
# state twice — once before the diff, once again after the confirm — so N=2 proves the post-confirm re-read is what the
# guard acts on, which is the whole reason that second read exists.
cat > "$T/bin/kubectl" <<'K'
#!/bin/bash
n=0; [ ! -f "$KSTATE" ] || n=$(cat "$KSTATE")
crd() { local dt=""; [ "$1" = dying ] && dt='"deletionTimestamp":"2026-08-28T00:00:00Z",'
  printf '{"items":[{"metadata":{%s"name":"widgets.test.glueops.dev","annotations":{},"labels":{}},"status":{"storedVersions":["v1"]}}]}' "$dt"; }
case "$1 ${2:-}" in
  "get crd")   n=$((n+1)); echo "$n" > "$KSTATE"
               if [ "$n" -ge "${GET_TERMINATING_FROM:-1}" ]; then crd dying; else crd clean; fi; exit 0;;
  "diff "*)    echo "diff -u -N a/widgets b/widgets"; exit 1;;                       # drift, so the confirm path runs
  "annotate "*|"label "*) echo "KUBECTL STRIP $*" >&2; exit 0;;
  "wait "*)    echo "KUBECTL WAIT $*" >&2; exit 1;;                                  # never clears, as a real finalizer would not
  "apply "*)   echo "KUBECTL APPLY REACHED $*"; exit 0;;                             # must never happen
esac
echo "KUBECTL $*"; exit 0
K
chmod +x "$T/bin/gum" "$T/bin/kubectl"
export PATH="$T/bin:$PATH" KSTATE="$T/kstate"

run() { local name=$1; shift; : > "$KSTATE"
  echo "##### $name #####"
  ( cd "$T/work" && environment=dev CRDS_AUTO_CONFIRM=yes CRDS_WAIT_TIMEOUT=1s "$@" "$CRDS" apply-dir "$T/bundle"; echo "RC=$?" ) > "$T/out" 2>&1 || echo "RC=$?" >> "$T/out"
  cat "$T/out"; }

run "A. terminating from the start: refuses, never applies" env GET_TERMINATING_FROM=1
expect "still terminating after 1s"
expect "the bundle was NOT applied"
refute "KUBECTL APPLY REACHED"
expect "RC=1"

run "B. clean before the confirm, terminating after: the re-read catches it" env GET_TERMINATING_FROM=2
expect "none terminating right now"          # the plan block, built from the pre-diff snapshot
expect "still terminating after 1s"          # ...and the post-confirm re-read disagreeing with it
refute "KUBECTL APPLY REACHED"
expect "RC=1"

run "C. never terminating: the apply is reached" env GET_TERMINATING_FROM=99
expect "KUBECTL APPLY REACHED"
refute "still terminating"

echo; echo "$(basename "$0"): $CASES assertions, FAILS=$FAILS"; [ "$FAILS" -eq 0 ]
