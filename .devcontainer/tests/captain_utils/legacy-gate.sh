#!/bin/bash
# The platform_crds_version gate: clusters whose captain repo pins it get their CRDs from the bundle (argocd step applies
# nothing); clusters without the pin keep the legacy ArgoCD CRD chooser + kubectl apply -k before helm upgrade; the crds
# item explains itself on such clusters; dev mode keeps the legacy chooser with Skip.
set -e -u -o pipefail
# shellcheck source=stubs.sh
source "$(dirname "$0")/stubs.sh"
# shellcheck disable=SC2034   # read by run_case (stubs.sh)
COMPONENT=argocd
run() { local n=$1 e=$2 fn=$3; shift 3; run_case "$n" "$e" "" "$fn" "$@"; }
mk() { mkdir -p "$T/work/VERSIONS"; printf 'versions:\n' > "$T/work/VERSIONS/glueops.yaml"; for kv in "$@"; do printf -- '- name: %s\n  version: "%s"\n' "${kv%%=*}" "${kv##*=}" >> "$T/work/VERSIONS/glueops.yaml"; done; }
NEW=(argocd_helm_chart_version=9.3.7 argocd_app_version=v3.2.12 platform_crds_version=v0.0.1)
OLD=(argocd_helm_chart_version=9.3.7 argocd_app_version=v3.2.12)

mk "${NEW[@]}"; run "A1 prod+pin: argocd step does NOT apply CRDs" production handle_argocd 9.3.7
expect "managed by the platform-crds bundle"; refute "KUBECTL apply"; refute "Select ArgoCD App Version"; expect "HELM upgrade --install argocd argo/argo-cd --version 9.3.7 .*--skip-crds"; expect "RC=0"
run "A2 prod+pin: crds item runs the bundle command" production handle_crds v0.0.1
expect "CRDS CMD target-version"; expect "CRDS CMD apply v0.0.1"; expect "RC=0"

mk "${OLD[@]}"; run "B1 prod, no pin: legacy chooser + kubectl apply -k ref=v3.2.12 before helm" production handle_argocd 9.3.7 v3.2.12
expect "Select ArgoCD App Version (legacy"; expect 'KUBECTL apply -k https://github.com/argoproj/argo-cd/manifests/crds?ref=v3.2.12'; expect "HELM repo update"; expect "Pre-commands complete"; expect "HELM upgrade .*--skip-crds"; expect "RC=0"
order_ok() { local a b; a=$(grep -n 'KUBECTL apply' "$T/out" | head -1 | cut -d: -f1); b=$(grep -n 'HELM upgrade' "$T/out" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
CASES=$((CASES+1)); if order_ok; then echo "  ok: CRDs applied before helm upgrade"; else echo "  FAIL: CRDs must be applied before helm upgrade"; FAILS=$((FAILS+1)); fi
run "B2 prod, no pin: crds item explains and returns 0 without calling the command" production handle_crds
expect "not on the platform-crds bundle yet"; refute "CRDS CMD"; expect "RC=0"
run "B3 prod, no pin, Skip: no CRD apply, helm still runs" production handle_argocd 9.3.7 Skip
refute "KUBECTL apply"; expect "HELM upgrade"; expect "RC=0"
run "B4 prod, no pin, Back at the CRD chooser: nothing runs" production handle_argocd 9.3.7 Back
refute "HELM diff"; refute "HELM upgrade"; expect "RC=0"
KUBECTL_APPLY_RC=1 run "B5 prod, no pin, kubectl apply fails: abort, loop offers again, Back" production handle_argocd 9.3.7 v3.2.12 Back
expect "Pre-commands failed"; refute "HELM upgrade"; expect "RC=0"
confirms 1; run "B6 prod, no pin, decline the upgrade: no apply" production handle_argocd 9.3.7 v3.2.12
refute "KUBECTL apply"; refute "HELM upgrade"; expect "RC=0"

rm -rf "$T/work/VERSIONS"; run "C1 dev: chooser lists the app_version of the chosen chart from helm search; apply -k ref=v3.2.12" dev handle_argocd 9.3.7 v3.2.12
expect 'GUM CHOOSE \[v3.2.12 Skip Back\]'; expect 'crds?ref=v3.2.12'; expect "HELM upgrade"; expect "RC=0"
run "C2 dev: crds item goes straight to the bundle command (no VERSIONS file needed)" dev handle_crds
expect "CRDS CMD target-version"; expect "CRDS CMD apply v0.0.1"; expect "RC=0"

mk argocd_helm_chart_version=9.3.7 argocd_app_version=v3.2.12 platform_crds_version=; run "D1 prod, pin present but empty: treated as not on the bundle (legacy)" production handle_argocd 9.3.7 Skip
expect "Select ArgoCD App Version (legacy"; expect "RC=0"
mk argocd_helm_chart_version=9.3.7 argocd_app_version=v3.2.12 platform_crds_version=platform_crds_version_placeholder; run "D2 prod, malformed pin (unrendered placeholder): legacy path, crds item explains" production handle_argocd 9.3.7 Skip
expect "Select ArgoCD App Version (legacy"; expect "RC=0"
run "D2b same repo: crds item does not run the command" production handle_crds
expect "no valid platform_crds_version pin"; refute "CRDS CMD"; expect "RC=0"

finish
