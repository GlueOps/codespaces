#!/bin/bash
# Offline test for browse_infrastructure's org -> cluster listing:
#   A. an org with no clusters anywhere shows a visible message (once) and returns cleanly
#      - guards the regression where the message was cleared before anyone could read it
#   B. no matching GitHub repos but clusters in AutoGlue: the menu is populated from the API
#   C. matching GitHub repos win: they populate the menu and /clusters is not consulted
# Everything is stubbed (gum, gh, api_call, clear) - no network, no docker, milliseconds.
set -u -o pipefail
cd "$(dirname "$0")/../../.." || exit 1

# Source the tool without executing main (the file's last line)
# shellcheck disable=SC1090  # non-constant source by design
source <(sed '$d' .devcontainer/tools/gluekube_ssh.sh)
set +e  # the sourced file turns on -e; assertions must run even after failures

# shellcheck disable=SC2034  # read by the sourced browse_infrastructure
API_ENDPOINT="https://stub.invalid/api/v1"
# shellcheck disable=SC2034
API_KEY="stub"

MENULOG=$(mktemp)   # every menu gum choose was offered
APILOG=$(mktemp)    # every api_call made
CNT=$(mktemp)       # gum choose call counter (file-based: stubs run in subshells)
OUT=$(mktemp)
cleanup() { rm -f "$MENULOG" "$APILOG" "$CNT" "$OUT"; }
trap cleanup EXIT

clear() { :; }
gh() { echo "$GH_REPOS"; }
gum() {
    case "$1" in
        style) echo "${@: -1}" ;;
        choose) cat >> "$MENULOG"
                local i; i=$(( $(cat "$CNT") + 1 )); echo "$i" > "$CNT"
                echo "${ANSWERS[$i]}" ;;
    esac
}
api_call() {
    echo "$1 $2" >> "$APILOG"
    case "$2" in
        /orgs) echo '[{"name":"acme","id":"org-1"}]' ;;
        /clusters) echo "$CLUSTERS_JSON" ;;
        *) echo '{}' ;;
    esac
}

reset_scenario() { : > "$MENULOG"; : > "$APILOG"; echo -1 > "$CNT"; : > "$OUT"; }

pass=0; fail=0
check() { # <desc> <extended-regex expected in file> <file>
    if grep -qE "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (missing: $2)"; fi
}
check_absent() { # <desc> <extended-regex that must NOT appear> <file>
    if grep -qE "$2" "$3"; then fail=$((fail+1)); echo "  FAIL: $1 (unexpected: $2)"; else pass=$((pass+1)); fi
}
check_eq() { # <desc> <actual> <expected>
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1 (got '$2', want '$3')"; fi
}

##### A. org with no clusters anywhere: visible message once, clean return #####
echo "##### A. empty org: message shown once, clean return #####"
reset_scenario
GH_REPOS=""; CLUSTERS_JSON='[]'
ANSWERS=("acme" "◀ Back")
browse_infrastructure > "$OUT" 2>&1 <<< "x"
check_eq "returns cleanly" "$?" "0"
check "no-clusters message shown" "No clusters found in organization 'acme'" "$OUT"
check_eq "message shown exactly once" "$(grep -cE "No clusters found in organization 'acme'" "$OUT")" "1"
# The real fix is the PAUSE: without it the org menu's clear wipes the message.
# The read's -p prompt only prints when stdin is a tty, so it can't be asserted
# on text; instead hold stdin open for ~1s and require the run to take that
# long - the old no-pause code returned in milliseconds.
start_ms=$(date +%s%3N)
ANSWERS=("acme" "◀ Back")
echo -1 > "$CNT"
sleep 1 | browse_infrastructure > "$OUT" 2>&1
elapsed_ms=$(( $(date +%s%3N) - start_ms ))
if (( elapsed_ms >= 900 )); then
    pass=$((pass+1))
else
    fail=$((fail+1)); echo "  FAIL: pauses at the message while stdin is open (took ${elapsed_ms}ms, want >=900)"
fi

##### B. no repos, clusters in AutoGlue: fallback populates the menu #####
echo "##### B. fallback: AutoGlue clusters populate the menu #####"
reset_scenario
GH_REPOS=""; CLUSTERS_JSON='[{"name":"prod.acme","id":"c1"},{"name":"stage.acme","id":"c2"}]'
ANSWERS=("acme" "◀ Back" "◀ Back")
browse_infrastructure > "$OUT" </dev/null
check_eq "returns cleanly" "$?" "0"
check "prod.acme offered in menu" "prod\.acme" "$MENULOG"
check "stage.acme offered in menu" "stage\.acme" "$MENULOG"
check "fallback consulted /clusters" "GET /clusters" "$APILOG"
check_absent "no empty-org message" "No clusters found" "$OUT"

##### C. matching repos win: menu from GitHub, /clusters not consulted for the list #####
echo "##### C. precedence: GitHub repos win, no /clusters call #####"
reset_scenario
GH_REPOS=$'web.acme\napi.acme'; CLUSTERS_JSON='[{"name":"prod.acme","id":"c1"}]'
ANSWERS=("acme" "◀ Back" "◀ Back")
browse_infrastructure > "$OUT" </dev/null
check_eq "returns cleanly" "$?" "0"
check "web.acme offered in menu" "web\.acme" "$MENULOG"
check "api.acme offered in menu" "api\.acme" "$MENULOG"
check_absent "AutoGlue name not in menu" "prod\.acme" "$MENULOG"
check_eq "/clusters never called" "$(grep -cE "GET /clusters" "$APILOG")" "0"
check_absent "no empty-org message" "No clusters found" "$OUT"

echo "browse-fallback.sh: $((pass + fail)) assertions, FAILS=$fail"
exit $(( fail > 0 ? 1 : 0 ))
