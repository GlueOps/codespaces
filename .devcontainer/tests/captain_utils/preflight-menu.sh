#!/bin/bash
# handle_app_chart_preflight: asks for the target, offers "all" plus the ApplicationSets in manifests/manifest.yaml, runs
# app-chart-preflight with --target (and --appset for one set), and maps its exit code to a message. Every path returns 0.
set -e -u -o pipefail
# shellcheck source=stubs.sh
source "$(dirname "$0")/stubs.sh"
cat > "$T/bin/pf-stub" <<'P'
#!/bin/bash
# stands in for app-chart-preflight: logs its arguments, exits $PF_RC (default 0)
echo "PREFLIGHT $*"; exit "${PF_RC:-0}"
P
chmod +x "$T/bin/pf-stub"
export CAPTAIN_UTILS_PREFLIGHT="$T/bin/pf-stub"
mkdir -p "$T/work/manifests"
cat > "$T/work/manifests/manifest.yaml" <<'M'
apiVersion: v1
kind: Namespace
metadata: {name: nonprod}
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: nonprod-application-set}
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: prod-application-set}
M
run() { local n=$1 e=$2 i=$3; shift 3; run_case "$n" "$e" "$i" handle_app_chart_preflight "$@"; }

run "F1 all sets, ok" production "0.18.0" all
expect 'GUM CHOOSE \[all nonprod-application-set prod-application-set Back\]'; expect "PREFLIGHT --target 0.18.0$"; expect "safe to bump all to 0.18.0"; expect "RC=0"
run "F2 one set" dev "v0.18.0" prod-application-set
expect "PREFLIGHT --target v0.18.0 --appset prod-application-set"; expect "RC=0"
PF_RC=1 run "F3 diff or error: do not bump, rc 0" production "0.18.0" all
expect "do NOT bump"; refute "safe to bump"; expect "RC=0"
PF_RC=2 run "F4 no verdict: rc 0" production "0.18.0" all
expect "no verdict (exit 2)"; expect "RC=0"
run "F5 empty target = back" production ""
refute "GUM CHOOSE"; refute "PREFLIGHT"; expect "RC=0"
run "F6 Back" production "0.18.0" Back
refute "PREFLIGHT"; expect "RC=0"
run "F7 spaces around the target are dropped" production "  0.18.0 " all
expect "PREFLIGHT --target 0.18.0$"; expect "RC=0"
mv "$T/work/manifests" "$T/manifests.away"
run "F8 no manifests/manifest.yaml: only all" production "0.18.0" all
expect 'GUM CHOOSE \[all Back\]'; expect "PREFLIGHT --target 0.18.0$"; expect "RC=0"
mv "$T/manifests.away" "$T/work/manifests"
CAPTAIN_UTILS_PREFLIGHT="$T/bin/not-there" run "F9 not installed" production "0.18.0"
expect "not installed"; refute "PREFLIGHT"; expect "RC=0"
run_case_raw "F10 EOF at the prompt = back" production "" handle_app_chart_preflight
refute "PREFLIGHT"; expect "RC=0"

finish
