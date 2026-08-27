#!/bin/bash
# handle_crds menu wiring: production offers <pinned> | custom | Back, dev's chooser lives inside the crds command; custom
# prompts for a local platform-crds checkout and runs "apply-dir <dir>"; failures print "NOT applied" and return 0.
set -e -u -o pipefail
# shellcheck source=stubs.sh
source "$(dirname "$0")/stubs.sh"
mkdir -p "$T/work/VERSIONS" "$T/local"; printf 'versions:\n- name: platform_crds_version\n  version: "v0.0.1"\n' > "$T/work/VERSIONS/glueops.yaml"
run() { local n=$1 e=$2 i=$3; shift 3; run_case "$n" "$e" "$i" handle_crds "$@"; }

run "M1 prod: pinned chosen -> apply v0.0.1" production "" v0.0.1
expect 'GUM CHOOSE \[v0.0.1 custom Back\]'; expect "CRDS CMD apply v0.0.1"; expect "RC=0"
run "M2 prod: custom -> warning, prompt, apply-dir <dir>" production "$T/local" custom
expect "UNRELEASED CRDs"; expect "CRDS CMD apply-dir $T/local"; refute "CRDS CMD apply v"; expect "RC=0"
run "M3 prod: Back" production "" Back
refute "CRDS CMD apply"; expect "RC=0"
run "M4 prod: custom, empty path = back" production "" custom
refute "CRDS CMD apply"; expect "RC=0"
TV_OUT=custom run "M5 dev: chooser inside the command returned custom -> prompt, apply-dir" dev "$T/local"
refute "GUM CHOOSE"; refute "UNRELEASED"; expect "CRDS CMD apply-dir $T/local"; expect "RC=0"
TV_OUT=v0.0.1 run "M6 dev: release chosen -> apply" dev ""
expect "CRDS CMD apply v0.0.1"; expect "RC=0"
APPLY_RC=1 run "M7 prod: apply-dir fails -> NOT applied, rc 0" production "$T/local" custom
expect "NOT applied"; expect "RC=0"

finish
