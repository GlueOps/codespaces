#!/bin/bash
# Structural guards: the pinned helm/kubectl command lines of the upgrade paths must stay byte-identical (pinned-lines.txt).
set -e -u -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(git -C "$HERE" rev-parse --show-toplevel)
CU=$REPO/.devcontainer/tools/captain_utils.sh
FAILS=0; CASES=0
check() { CASES=$((CASES+1)); if "$@"; then echo "  ok: $*"; else echo "  FAIL: $*"; FAILS=$((FAILS+1)); fi; }
pinned_lines_present() { local line; while IFS= read -r line; do grep -qFx -- "$line" "$CU" || { echo "    missing pinned line: $line"; return 1; }; done < "$HERE/pinned-lines.txt"; }
echo "##### pinned command lines #####"
check pinned_lines_present
echo; echo "$(basename "$0"): $CASES assertions, FAILS=$FAILS"; [ "$FAILS" -eq 0 ]
