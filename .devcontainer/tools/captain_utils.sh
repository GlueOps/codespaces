#!/bin/bash
environment=production
BUCKET_NAME="helm-diff"
CAPTAIN_CLUSTER_NAME=$(basename $(pwd))
set -e
set -u
set -o pipefail

run_prerequisite_commands(){
    helm repo update
}

check_codespace_version_match(){
    codespace_version=`yq '.versions[] | select(.name == "codespace_version") | .version' VERSIONS/glueops.yaml`
    if [ "$codespace_version" != $VERSION ]; then
        gum style --foreground 196 --bold "Current codespace version doesn't match with the desired: ${codespace_version}"
        if ! gum confirm "Confirmation"; then
            return 1
        fi
    fi
}

upload_diff() {
    gum log --structured --level info "Uploading helm-diff output to ..."
}

show_diff_table(){
    command_args=("/usr/local/py-utils/venvs/pyaml/bin/python" "/usr/local/bin/script_captain_utils" "--write-diff-csv" "--base-path" $PWD)
    "${command_args[@]}"
    gum style --foreground 196 --bold "Note: any field that contains aestrick(*) is not live version" 
    gum table \
        --file /tmp/captain_utils_diff.csv \
        --separator "," \
        --header.foreground "#FFAA00" \
        --header.bold \
        --cell.align "center" \
        --cell.border-foreground "63"
}

# ---- layer-0 CRD bundle (GlueOps/platform-crds) ----
# The CRD logic lives in its own internal command (.devcontainer/libexec/captain_utils/crds, installed by the
# Dockerfile to /usr/local/libexec/captain_utils/crds — deliberately OFF the PATH so nobody runs it by accident).
# It is run as a subprocess by absolute path, not sourced, so nothing in it can leak into this menu shell.
CAPTAIN_UTILS_CRDS="${CAPTAIN_UTILS_CRDS:-/usr/local/libexec/captain_utils/crds}"

# A cluster is on the platform-crds bundle once its captain repo pins platform_crds_version in VERSIONS/glueops.yaml
# (written by the terraform module). Captain repos that predate the pin keep the legacy path: ArgoCD's CRDs are
# applied from upstream by the argocd step, everything else by the ArgoCD Applications. Dev mode has no VERSIONS
# file, so it is never "on the bundle" here and the argocd step offers Skip instead.
crds_bundle_enabled() {
    [ "$environment" = "production" ] || return 1
    [ -f VERSIONS/glueops.yaml ] || return 1
    local v
    v=$(yq '.versions[] | select(.name == "platform_crds_version") | .version' VERSIONS/glueops.yaml 2>/dev/null) || return 1
    [ -n "$v" ] && [ "$v" != "null" ]
}

# menu item "crds" — run BEFORE argocd and AGAIN AFTER argocd (second run is a no-op unless the argocd release removed a CRD).
# Never propagates a non-zero status into the `set -e` menu loop.
handle_crds() {
    local v choice dir
    if [ "$environment" = "production" ] && ! crds_bundle_enabled; then
        gum style --foreground 214 "This cluster is not on the platform-crds bundle yet: VERSIONS/glueops.yaml has no platform_crds_version pin."
        gum style --foreground 214 "ArgoCD's CRDs are still applied by the argocd step. Bump the terraform module and 'terraform apply' the captain repo to enable the bundle."
        return 0
    fi
    if [ ! -x "$CAPTAIN_UTILS_CRDS" ]; then
        gum style --foreground 196 "❌ $CAPTAIN_UTILS_CRDS is missing or not executable — rebuild the codespace image"; return 0
    fi
    if ! v=$(environment="$environment" "$CAPTAIN_UTILS_CRDS" target-version); then gum style --foreground 196 "❌ could not determine the platform-crds version"; return 0; fi
    if [ "$v" = "Back" ]; then return 0; fi
    if [ "$environment" = "production" ]; then
        choice=$(gum choose "$v" "custom" "Back") || return 0   # dev: the release chooser inside target-version already offers custom
    else
        choice="$v"
    fi
    case "$choice" in
        Back) return 0 ;;
        custom)
            # custom: apply the bundle from a local checkout of GlueOps/platform-crds (after hack/render.sh)
            if [ "$environment" = "production" ]; then
                gum style --foreground 196 --bold "⚠️  custom applies UNRELEASED CRDs to this cluster. Nothing records it afterwards (same field manager as the pinned bundle) — the next pinned run's diff shows what it changed."
            fi
            gum style "Local platform-crds directory — a checkout of GlueOps/platform-crds with crds/ rendered (Tab completes, empty = back):"
            if ! dir=$(ask_dir "$PLATFORM_CHART_DIR_PREFILL"); then return 0; fi
            if [ -z "$dir" ]; then return 0; fi
            if ! environment="$environment" "$CAPTAIN_UTILS_CRDS" apply-dir "$dir"; then gum style --foreground 196 "platform-crds from $dir NOT applied"; fi
            ;;
        *)
            if ! environment="$environment" "$CAPTAIN_UTILS_CRDS" apply "$v"; then gum style --foreground 196 "platform-crds $v NOT applied"; fi
            ;;
    esac
    return 0
}

handle_platform_upgrades() {
    # Handle exit option
    if [ "$environment" = "production" ]; then
        platform_version_string=`yq '.versions[] | select(.name == "glueops_platform_helm_chart_version") | .version' VERSIONS/glueops.yaml`
    else
        platform_version_string=$(gh release list --repo GlueOps/platform-helm-chart-platform --limit 10 --json tagName --jq '.[].tagName' | paste -sd' ' -)
    fi
    
    while true; do
        versions=(${platform_version_string})
        target_file="platform.yaml"
        overrides_file="platform.yaml"
        namespace="glueops-core"
        chart_name="glueops-platform/glueops-platform"

        if [ -e "overrides.yaml" ]; then
            gum style --foreground 212 --bold "Overrides.yaml detected"
            overrides_file="overrides.yaml"
        else
            gum style --foreground 196 --bold "No Overrides.yaml detected"
            overrides_file="platform.yaml"
        fi
        version=$(gum choose "${versions[@]}" "custom" "Back")
        
        # Check if user wants to go back
        if [ "$version" = "Back" ]; then
            return
        fi
        # custom: install the chart from a local directory (feature testing)
        if [ "$version" = "custom" ]; then
            handle_platform_custom "$overrides_file"
            return
        fi
        echo "chosen version: $version for $chart_name"

        helm_diff_cmd="helm diff --color upgrade \"$component\" \"$chart_name\" --version \"$version\" -f \"$target_file\" -f \"$overrides_file\" -n \"$namespace\" --allow-unreleased"
        
        set -x
        eval "$helm_diff_cmd | gum pager" # Execute the main helm diff command
        gum style --bold --foreground 212 "✅ Diff complete."
        set +x
        
        if ! gum confirm "Apply upgrade"; then
            return
        fi
        
        # Running helm diff command
        gum style --bold --foreground 212 "The following commands will be executed:"
        
        set -x
        helm upgrade --install "$component" "$chart_name" --version "$version" -f "$target_file" -f "$overrides_file" -n "$namespace" --create-namespace 
        set +x
        return 
    done
}

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
    [ -n "$d" ] || return 0
    ( CDPATH='' cd -- "$d" >/dev/null 2>&1 && pwd -P ) || printf '%s\n' "$d"
}

# dir_git_info DIR — "branch@sha" plus ", dirty" when DIR is inside a git checkout with uncommitted changes; empty
# otherwise. GIT_DIR/GIT_WORK_TREE are dropped so an operator's exported values cannot point this at the captain repo.
dir_git_info() {
    local dir="$1" branch sha dirty=""
    g() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$dir" "$@"; }
    g rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    sha=$(g rev-parse --short HEAD 2>/dev/null) || return 0
    branch=$(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    [ -z "$(g status --porcelain -- . 2>/dev/null)" ] || dirty=", dirty"
    printf '%s@%s%s' "$branch" "$sha" "$dirty"
}

# ---- glueops-platform "custom": install the platform chart from a local directory ----
# For testing local changes: point at a checkout of GlueOps/platform-helm-chart-platform (the chart has no
# dependencies, so helm diffs/upgrades it straight from the directory, .helmignore respected). Flow: path prompt ->
# show path, chart name/version and branch@sha (+dirty) -> confirm -> the same diff -> confirm -> upgrade flow as the
# pinned path (keep the helm lines in sync with handle_platform_upgrades). The release is stamped with
# --description "custom: <dir> (<branch>@<sha>[, dirty])" so `helm history glueops-platform -n glueops-core` shows what
# is really installed (per revision: the next pinned upgrade records "Upgrade complete" again). Never propagates a
# non-zero status into the `set -e` menu loop.
PLATFORM_CHART_DIR_PREFILL="${PLATFORM_CHART_DIR_PREFILL:-/workspaces/}"

handle_platform_custom() {
    local overrides_file="$1"
    local dir
    if [ "$environment" = "production" ]; then
        gum style --foreground 196 --bold "⚠️  custom installs an UNRELEASED chart on this cluster. The VERSIONS/glueops.yaml pin will no longer describe what is running, and show_diff_table will usually NOT show it (feature branches keep main's Chart.yaml version) — 'helm history $component -n glueops-core' is the only record. Re-run glueops-platform with the pinned version to get back."
    fi
    gum style "Local chart directory — a checkout of GlueOps/platform-helm-chart-platform (Tab completes, empty = back):"
    if ! dir=$(ask_dir "$PLATFORM_CHART_DIR_PREFILL"); then return 0; fi
    if [ -z "$dir" ]; then return 0; fi
    handle_platform_custom_dir "$dir" "$overrides_file" || true
    return 0
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

handle_argocd() {
    if [ "$environment" = "production" ]; then
        argocd_version=`yq '.versions[] | select(.name == "argocd_helm_chart_version") | .version' VERSIONS/glueops.yaml`
    else
        argocd_version=($(helm search repo  argo/argo-cd --versions -o json | jq -r "limit(30; .[]).version" | paste -sd' ' -)) 
    fi
    while true; do
        unset helm_diff_cmd # Clear variables to avoid stale values
        local versions=() # Initialize versions array for each iteration
        # Show version selection
        versions=("${argocd_version[@]}")
        target_file="argocd.yaml"
        namespace="glueops-core"
        chart_name="argo/argo-cd"
        version=$(gum choose "${versions[@]}" "Back")
        
        # Check if user wants to go back
        if [ "$version" = "Back" ]; then
            return
        fi
        echo "chosen version: $version for $chart_name"

        helm_diff_cmd="helm diff --color upgrade \"$component\" \"$chart_name\" --version \"$version\" -f \"$target_file\" -n \"$namespace\" --allow-unreleased"
        
        # ArgoCD's CRDs: on clusters that pin platform_crds_version they come from the platform-crds bundle (menu
        # item "crds", run before and after this step) and nothing is applied here. Clusters without the pin keep
        # the legacy path below: apply ArgoCD's CRDs from upstream before the helm upgrade (the chart runs with
        # --skip-crds either way).
        local pre_commands=""
        local chosen_crd_version=""
        if crds_bundle_enabled; then
            gum style --foreground 212 "ArgoCD CRDs are managed by the platform-crds bundle (menu item crds) — not applied by this step."
        else
            gum style --bold --foreground 212 "Select ArgoCD App Version (legacy CRD install — this cluster is not on the platform-crds bundle):"
            local argocd_crd_versions=()
            if [ "$environment" = "production" ]; then
                mapfile -t argocd_crd_versions < <(yq '.versions[] | select(.name == "argocd_app_version") | .version' VERSIONS/glueops.yaml)
            else
                mapfile -t argocd_crd_versions < <(helm search repo argo/argo-cd --versions -o json | jq -r --arg v "$version" '.[] | select(.version == $v).app_version')
            fi
            chosen_crd_version=$(gum choose "${argocd_crd_versions[@]}" "Skip" "Back")
            if [ "$chosen_crd_version" = "Back" ]; then
                return
            fi
            if [ "$chosen_crd_version" != "Skip" ]; then
                pre_commands="kubectl apply -k \"https://github.com/argoproj/argo-cd/manifests/crds?ref=$chosen_crd_version\" && helm repo update"
            fi
        fi

        set -x
        eval "$helm_diff_cmd | gum pager" # Execute the main helm diff command
        gum style --bold --foreground 212 "✅ Diff complete."
        set +x
        
        if ! gum confirm "Apply upgrade"; then
            return
        fi
        
        # Running helm diff command
        gum style --bold --foreground 212 "The following commands will be executed:"
        
        # Legacy CRD install (clusters without the platform_crds_version pin only)
        if [ -n "$pre_commands" ]; then
            gum style --bold --foreground 212 "Executing pre-commands for $component:"
            set -x
            if ! eval "$pre_commands"; then
                gum style --bold --foreground 196 "❌ Pre-commands failed. Aborting."
                set +x
                continue # Allow user to retry or go back
            fi
            set +x
            gum style --bold --foreground 212 "✅ Pre-commands complete."
        fi
        set -x
        helm upgrade --install "$component" "$chart_name" --version "$version" -f "$target_file"  -n "$namespace" --create-namespace --skip-crds
        set +x
        return 
    done

}

handle_calico_upgrades() {
    calico_version=`yq '.versions[] | select(.name == "calico_helm_chart_version") | .version' VERSIONS/glueops.yaml`
    remove_daemonset='kubectl delete daemonset -n kube-system aws-node'
    gum style --bold --foreground 196 "Removing eks daemonset" 
    set -x
    ${remove_daemonset} || true
    
    gum style --bold --foreground 196 "Deploying calico helm chart ${calico_version}"
    
    helm repo add projectcalico https://docs.tigera.io/calico/charts
    helm repo update
    helm upgrade --install calico projectcalico/tigera-operator --version ${calico_version} --namespace tigera-operator -f calico.yaml --create-namespace
    
    set +x

}

handle_terraform_addons() {
    command_args=("/usr/local/py-utils/venvs/pyaml/bin/python" "/usr/local/bin/script_captain_utils" "--upgrade-addons" "--base-path" $PWD)
    "${command_args[@]}"
}
handle_terraform_nodepools() {
    command_args=("/usr/local/py-utils/venvs/pyaml/bin/python" "/usr/local/bin/script_captain_utils" "--upgrade-ami-version" "--base-path" $PWD)
    "${command_args[@]}"
}

handle_kubernetes_version() {
    command_args=("/usr/local/py-utils/venvs/pyaml/bin/python" "/usr/local/bin/script_captain_utils" "--upgrade-kubernetes-version" "--base-path" $PWD)
    "${command_args[@]}"
}


handle_aws_options() {
    local aws_component=$(gum choose "calico" "eks-addons" "upgrade-eks-nodepools" "upgrade-kubernetes" "Exit")
    # Handle exit option
    if [ "$aws_component" = "Exit" ]; then
        echo "Goodbye!"
        exit 0
    fi

    if [ "$aws_component" = "calico" ]; then
        handle_calico_upgrades
    fi

    if [ "$aws_component" = "eks-addons" ]; then
        handle_terraform_addons
    fi

    if [ "$aws_component" = "upgrade-eks-nodepools" ]; then
        handle_terraform_nodepools
    fi
    
    if [ "$aws_component" = "upgrade-kubernetes" ]; then
        handle_kubernetes_version
    fi
   
}

handle_inspect_pods() {
    gum style --bold --foreground 212 "Inspecting pods in the cluster"
    watch -n 5 'kubectl get pods -A | grep "Pending\|CrashLoopBackOff\|Error\|ContainerCreating\|ImagePullBackOff\|ErrImagePull" || true'
}

show_production(){
    while true; do
        component=$(gum choose "show_diff_table" "crds" "argocd" "glueops-platform" "aws" "inspect_pods" "Exit")

        # Handle exit option
        if [ "$component" = "Exit" ]; then
            echo "Goodbye!"
            exit 0
        fi

        if [ "$component" = "show_diff_table" ]; then
            gum style --bold --foreground 212 "Showing diff table before proceeding"
            show_diff_table
        fi

        if [ "$component" = "aws" ]; then
            handle_aws_options
        fi

        if [ "$component" = "glueops-platform" ]; then
            handle_platform_upgrades
        fi

        # crds (platform-crds bundle) must be run BEFORE argocd and AGAIN AFTER argocd:
        # the argocd release drops the Gate CRD it used to own and the second run recreates it.
        if [ "$component" = "crds" ]; then
            handle_crds
        fi

        if [ "$component" = "argocd" ]; then
            handle_argocd
        fi
        
        if [ "$component" = "inspect_pods" ]; then
            handle_inspect_pods
        fi
       
    done
}

show_dev(){
    while true; do
        component=$(gum choose "crds" "argocd" "glueops-platform" "aws" "Exit")
        
        # Handle exit option
        if [ "$component" = "Exit" ]; then
            echo "Goodbye!"
            exit 0
        fi

        if [ "$component" = "aws" ]; then
            handle_aws_options
        fi

        if [ "$component" = "glueops-platform" ]; then
            handle_platform_upgrades
        fi

        # crds (platform-crds bundle) must be run BEFORE argocd and AGAIN AFTER argocd:
        # the argocd release drops the Gate CRD it used to own and the second run recreates it.
        if [ "$component" = "crds" ]; then
            handle_crds
        fi

        if [ "$component" = "argocd" ]; then
            handle_argocd
        fi

        
    done
}

check_codespace_version_match
run_prerequisite_commands

while true; do
    # Show main menu
    environment=$(gum choose "dev" "production" "Exit")

    # Handle exit option
    if [ "$environment" = "Exit" ]; then
        echo "Goodbye!"
        exit 0
    fi

    if [ "$environment" = "production" ]; then
        show_production
    fi
    
    if [ "$environment" = "dev" ]; then
        show_dev
    fi
done
