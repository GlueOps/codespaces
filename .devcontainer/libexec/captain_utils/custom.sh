# shellcheck shell=bash
# shellcheck disable=SC2154   # `component` is a menu global (rule 6)
# captain_utils/custom.sh — sourced by /usr/local/bin/captain_utils at startup. NOT executable, NOT on the PATH.
#
# Contract (guarded by .devcontainer/tests/captain_utils/contract.sh; run hack/test.sh):
#  1. Definitions only: function definitions and nothing else — no top-level commands, assignments, set/shopt/trap/exit
#     or source. It is loaded under the menu's `set -e -u -o pipefail`; a top-level failure would kill the menu at startup.
#  2. No shebang, mode 644: this file is never executed.
#  3. Exactly these functions, in this order: ask_dir, dir_git_info, handle_platform_custom_dir. Adding one means adding
#     it here and to the declare -F assertion in contract.sh.
#  4. Names: handle_* is a menu flow that always returns 0 or is called with `|| true`; everything else is a helper named
#     verb_noun / noun_info that takes its inputs as positional parameters. No nested functions (they leak as globals).
#  5. Globals out: none — every variable is local or a parameter (PLATFORM_CHART_DIR_PREFILL stays in the menu).
#  6. Globals in: `component` only (the release name, set by show_production/show_dev).
#  7. Leave the shell as you found it: set -x inside a flow is fine, but every early return runs set +x first.
#  8. Return codes: handle_platform_custom_dir returns 1 on any refusal/failure after one ❌ line, 0 on success or
#     operator decline; ask_dir returns 1 only on EOF; dir_git_info always returns 0 (empty output = not a git checkout).
#  9. Keep in sync with the pinned path: the helm diff/upgrade lines mirror handle_platform_upgrades in captain_utils.sh
#     except "$dir" for chart+version and --description. Change one, change both (the pinned one is in pinned-lines.txt).
# 10. Lint clean: shellcheck -S warning reports nothing beyond the file-level SC2154 above; per-line disables carry a reason.
# 11. Tests source the real files (captain_utils.sh sources this one); never awk/sed a function out again.

# ---- "custom": local directories for feature testing ----
# ask_dir PREFILL — readline path prompt (Tab completes paths, Ctrl-U clears the prefill, empty line = back).
# Prints the absolute path (~ expanded, relative resolved against $PWD, trailing / dropped); prints nothing on empty
# input; returns 1 on EOF. When stdin is not a terminal, read -e degrades to a plain read (scriptable).
ask_dir() {
    local d
    # no -r: readline escapes spaces/backslashes on Tab-completion ("with\ space/") and a plain read unescapes them again
    read -e -i "$1" -p "path> " d || return 1
    # shellcheck disable=SC2088   # literal pattern match on a typed ~, expanded by hand below
    case "$d" in '~') d=$HOME ;; '~/'*) d="$HOME${d#\~}" ;; esac
    [ "$d" = / ] || d="${d%/}"
    [ "$d" != - ] || d=./-   # never let cd read a bare '-' as "previous directory"
    [ -n "$d" ] || return 0
    ( CDPATH='' cd -- "$d" >/dev/null 2>&1 && pwd -P ) || printf '%s\n' "$d"
}

# dir_git_info DIR — "branch@sha" plus ", dirty" when DIR is inside a git checkout with uncommitted changes; empty
# otherwise. GIT_DIR/GIT_WORK_TREE are dropped so an operator's exported values cannot point this at the captain repo.
dir_git_info() {
    local dir="$1" branch sha dirty=""
    local -a g=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$dir")   # an array, not a nested function (rule 4)
    "${g[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    sha=$("${g[@]}" rev-parse --short HEAD 2>/dev/null) || return 0
    branch=$("${g[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    [ -z "$("${g[@]}" status --porcelain -- . 2>/dev/null)" ] || dirty=", dirty"
    printf '%s@%s%s' "$branch" "$sha" "$dirty"
}

handle_platform_custom_dir() {
    local dir="$1" overrides_file="$2"
    local target_file="platform.yaml" namespace="glueops-core"
    local chart_name chart_version git_info
    if [ ! -d "$dir" ]; then gum style --foreground 196 "❌ '$dir' is not a directory"; return 1; fi
    if [ ! -f "$dir/Chart.yaml" ]; then
        gum style --foreground 196 "❌ '$dir' has no Chart.yaml — point at a checkout of GlueOps/platform-helm-chart-platform"; return 1
    fi
    if ! chart_name=$(yq -e '.name' "$dir/Chart.yaml" 2>/dev/null) || [ -z "$chart_name" ] || [ "$chart_name" = null ]; then
        gum style --foreground 196 "❌ cannot read .name from $dir/Chart.yaml"; return 1
    fi
    if ! chart_version=$(yq -e '.version' "$dir/Chart.yaml" 2>/dev/null) || [ -z "$chart_version" ] || [ "$chart_version" = null ]; then
        gum style --foreground 196 "❌ cannot read .version from $dir/Chart.yaml"; return 1
    fi
    git_info=$(dir_git_info "$dir")
    gum style --foreground 212 --bold "chart $chart_name $chart_version from $dir${git_info:+ ($git_info)}"
    if [ "$chart_name" != "$component" ]; then
        gum style --foreground 214 "note: Chart.yaml name is '$chart_name' but it will be installed as release '$component' in $namespace"
    fi
    gum style "helm list will show $component-$chart_version; the directory is recorded only in the release description: custom: $dir${git_info:+ ($git_info)}"
    if ! gum confirm "Diff this chart against the cluster?"; then
        return 0
    fi

    set -x
    if ! helm diff --color upgrade "$component" "$dir" -f "$target_file" -f "$overrides_file" -n "$namespace" --allow-unreleased | gum pager; then
        set +x
        gum style --foreground 196 "❌ helm diff failed"; return 1
    fi
    set +x
    gum style --bold --foreground 212 "✅ Diff complete."

    if ! gum confirm "Apply upgrade"; then
        return 0
    fi

    gum style --bold --foreground 212 "The following commands will be executed:"
    set -x
    if ! helm upgrade --install "$component" "$dir" -f "$target_file" -f "$overrides_file" -n "$namespace" --create-namespace --description "custom: $dir${git_info:+ ($git_info)}"; then
        set +x
        gum style --foreground 196 "❌ helm upgrade failed"; return 1
    fi
    set +x
    gum style --bold --foreground 212 "✅ $component installed from $dir (helm history $component -n $namespace shows the description)"
    return 0
}
