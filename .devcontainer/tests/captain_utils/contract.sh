#!/bin/bash
# Structural guards for the captain_utils split (see the contract in libexec/captain_utils/custom.sh):
# the library is definitions-only and exports exactly its three functions, no name is defined twice across the menu and
# the library, sourcing the menu runs no menu, the library is installed off the PATH with mode 644, and the pinned
# helm/kubectl command lines of the upgrade paths are byte-identical to pinned-lines.txt.
set -e -u -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(git -C "$HERE" rev-parse --show-toplevel)
CU=$REPO/.devcontainer/tools/captain_utils.sh
LIBEXEC=$REPO/.devcontainer/libexec/captain_utils
LIB=$LIBEXEC/custom.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILS=0; CASES=0
check() { CASES=$((CASES+1)); if "$@"; then echo "  ok: $*"; else echo "  FAIL: $*"; FAILS=$((FAILS+1)); fi; }

echo "##### library: definitions only #####"
lib_sources_silently() { local out; out=$(bash -c 'set -e -u -o pipefail; source "$1"' _ "$LIB" 2>&1) && [ -z "$out" ]; }
lib_defines_exactly() { [ "$(bash -c 'source "$1"; declare -F | sed "s/declare -f //"' _ "$LIB" | paste -sd' ' -)" = "ask_dir dir_git_info handle_platform_custom_dir" ]; }
lib_no_toplevel_commands() { ! grep -nE '^(set |shopt |exit\b|trap |source |\. |[A-Za-z_][A-Za-z0-9_]*=)' "$LIB"; }
lib_no_shebang() { [ "$(head -c2 "$LIB")" != "#!" ]; }
check lib_sources_silently
check lib_defines_exactly
check lib_no_toplevel_commands
check lib_no_shebang
lib_leaves_nothing_behind() { bash -c 'source "$1"; before=$(declare -F | wc -l); dir_git_info "$2" >/dev/null; [ "$(declare -F | wc -l)" = "$before" ] && ! declare -F g >/dev/null' _ "$LIB" "$REPO"; }
check lib_leaves_nothing_behind

echo "##### menu + library: no duplicate function names #####"
no_duplicate_names() { [ -z "$(grep -ohE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$CU" "$LIB" | sort | uniq -d)" ]; }
check no_duplicate_names

echo "##### sourcing the menu defines its functions and runs nothing #####"
mkdir -p "$T/bin"; printf '#!/bin/bash\necho "$@" >> "%s/gum.log"\n' "$T" > "$T/bin/gum"; chmod +x "$T/bin/gum"
menu_sources_quietly() {
    local out
    out=$(cd "$T" && PATH="$T/bin:$PATH" CAPTAIN_UTILS_LIBEXEC="$LIBEXEC" bash -c 'set -e -u -o pipefail; source "$1"; declare -F handle_argocd >/dev/null && declare -F handle_platform_custom_dir >/dev/null && echo defined' _ "$CU" 2>&1)
    [ "$out" = "defined" ] && [ ! -e "$T/gum.log" ]
}
check menu_sources_quietly
menu_fails_loudly_without_library() { local out; out=$(CAPTAIN_UTILS_LIBEXEC=/nonexistent bash "$CU" 2>&1) && return 1; [[ "$out" == *"custom.sh is missing"* ]]; }
check menu_fails_loudly_without_library

echo "##### install layout: library under libexec (off the PATH), mode 644 #####"
lib_mode_644() { [ "$(git -C "$REPO" ls-files -s .devcontainer/libexec/captain_utils/custom.sh | cut -d' ' -f1)" = "100644" ]; }
lib_not_under_tools() { [ ! -e "$REPO/.devcontainer/tools/custom.sh" ]; }
check lib_mode_644
check lib_not_under_tools

echo "##### pinned command lines #####"
pinned_lines_present() { local line; while IFS= read -r line; do grep -qFx -- "$line" "$CU" || { echo "    missing pinned line: $line"; return 1; }; done < "$HERE/pinned-lines.txt"; }
check pinned_lines_present

echo; echo "$(basename "$0"): $CASES assertions, FAILS=$FAILS"; [ "$FAILS" -eq 0 ]
