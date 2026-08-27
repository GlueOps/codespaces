# shellcheck shell=bash
# Shared fixtures for the captain_utils harnesses (.devcontainer/tests/captain_utils/*.sh): a PATH shim that replaces
# gum/helm/kubectl and the crds command with stubs that print their arguments, a run_case helper that executes one menu
# function under `set -e -u -o pipefail` exactly as captain_utils does, and expect/refute assertions with a FAILS counter.
# No cluster, no network. Sourced by each harness; harnesses run with `set -e -u -o pipefail`.
REPO=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
CU=$REPO/.devcontainer/tools/captain_utils.sh
export CAPTAIN_UTILS_LIBEXEC=$REPO/.devcontainer/libexec/captain_utils
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/work"

# ---- stubs ----
cat > "$T/bin/gum" <<'G'
#!/bin/bash
# style -> "GUM: text"; choose -> next line of $GUM_PICKS_FILE (must be one of the options); confirm -> next line of
# $GUM_CONFIRM_FILE as its exit code (empty file = 0); input -> $GUM_INPUT; pager -> cat
case "$1" in
  style) shift; while [ $# -gt 0 ] && [[ "$1" == --* ]]; do [ "$1" = "--foreground" ] && shift; shift; done; echo "GUM: $*";;
  choose) shift; pick=$(head -1 "$GUM_PICKS_FILE"); sed -i '1d' "$GUM_PICKS_FILE"; echo "GUM CHOOSE [$*] -> $pick" >&2
          for o in "$@"; do [ "$o" = "$pick" ] && { echo "$pick"; exit 0; }; done; echo "STUB: pick '$pick' not offered" >&2; exit 1;;
  confirm) shift; n=$(head -1 "$GUM_CONFIRM_FILE" 2>/dev/null || true); n=${n:-0}; sed -i '1d' "$GUM_CONFIRM_FILE" 2>/dev/null || true; echo "GUM CONFIRM '$*' -> rc=$n" >&2; exit "$n";;
  input) [ "${GUM_INPUT_RC:-0}" = 0 ] || exit "$GUM_INPUT_RC"; printf '%s\n' "${GUM_INPUT:-}";;
  pager) cat;;
esac
G
cat > "$T/bin/helm" <<'H'
#!/bin/bash
# prints "HELM <args>"; diff/upgrade exit with $HELM_DIFF_RC / $HELM_UPGRADE_RC (default 0); search returns two argo-cd versions
case "$1" in
  search) echo '[{"version":"9.3.7","app_version":"v3.2.12"},{"version":"9.3.6","app_version":"v3.2.11"}]'; exit 0;;   # parsed by jq: JSON only
esac
echo "HELM $*"
case "$1" in diff) [ "${HELM_DIFF_RC:-0}" = 0 ];; upgrade) [ "${HELM_UPGRADE_RC:-0}" = 0 ];; esac
H
cat > "$T/bin/kubectl" <<'K'
#!/bin/bash
echo "KUBECTL $*"; [ "${KUBECTL_APPLY_RC:-0}" = 0 ]
K
cat > "$T/bin/crds-cmd" <<'C'
#!/bin/bash
# stands in for libexec/captain_utils/crds: logs the call, target-version prints $TV_OUT (default v0.0.1), apply* exit $APPLY_RC
echo "CRDS CMD $*" >&2
case "$1" in target-version) echo "${TV_OUT:-v0.0.1}";; apply|apply-dir) exit "${APPLY_RC:-0}";; esac
C
cat > "$T/bin/gh" <<'R'
#!/bin/bash
# dev mode lists chart releases with `gh release list ... --json tagName --jq .[].tagName`: two fixed tags, no network
case "$1 $2" in "release list") printf 'v0.77.0\nv0.76.0\n';; *) echo "gh stub: unexpected call: $*" >&2; exit 1;; esac
R
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" CAPTAIN_UTILS_CRDS="$T/bin/crds-cmd" GUM_PICKS_FILE="$T/picks" GUM_CONFIRM_FILE="$T/confirms"
: > "$GUM_PICKS_FILE"; : > "$GUM_CONFIRM_FILE"

# ---- code under test ----
# run_case sources the real captain_utils.sh (which sources libexec/captain_utils/custom.sh); the file returns
# before its main loop when sourced.
UNDER_TEST="source '$CU'"

# run_case NAME ENV STDIN FN PICKS... — runs FN in $T/work with the given stdin (a trailing newline is added; use
# run_case_raw for byte-exact stdin) and gum choose picks; captures stdout+stderr and "RC=<status>" into $T/out.
# COMPONENT (default glueops-platform) and PLATFORM_VERSIONS (default v0.77.0) parameterise the menu globals.
run_case() { local name=$1 env=$2 input=$3 fn=$4; shift 4; printf '%s\n' "$input" | _run_case "$name" "$env" "$fn" "$@"; }
run_case_raw() { local name=$1 env=$2 input=$3 fn=$4; shift 4; printf '%s' "$input" | _run_case "$name" "$env" "$fn" "$@"; }
_run_case() { local name=$1 env=$2 fn=$3; shift 3; printf '%s\n' "$@" > "$GUM_PICKS_FILE"
  ( cd "$T/work" && environment="$env" component="${COMPONENT:-glueops-platform}" platform_version_string="${PLATFORM_VERSIONS:-v0.77.0}" \
      bash -c "set -e -u -o pipefail; $UNDER_TEST; environment='$env'; $fn; echo \"RC=\$?\"" ) > "$T/out" 2>&1 || echo "RC=$?" >> "$T/out"
  echo "##### $name #####"; cat "$T/out"; }

# ---- assertions ----
FAILS=0; CASES=0
expect() { CASES=$((CASES+1)); if grep -q -- "$1" "$T/out"; then echo "  ok: $1"; else echo "  FAIL: missing '$1'"; FAILS=$((FAILS+1)); fi; }
refute() { CASES=$((CASES+1)); if grep -q -- "$1" "$T/out"; then echo "  FAIL: unexpected '$1'"; FAILS=$((FAILS+1)); else echo "  ok: no '$1'"; fi; }
confirms() { printf '%s\n' "$@" > "$GUM_CONFIRM_FILE"; }   # exit codes for the next gum confirm calls, in order (empty = all 0)
finish() { echo; echo "$(basename "$0"): $CASES assertions, FAILS=$FAILS"; [ "$FAILS" -eq 0 ]; }
