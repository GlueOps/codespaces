#!/bin/bash
environment=production
BUCKET_NAME="helm-diff"
CAPTAIN_CLUSTER_NAME=$(basename $(pwd))
set -e
set -u
set -o pipefail

# --- Flow mode infrastructure ---
FLOW_MODE=false
FLOW_QUEUE=()
# Use a temp file for FLOW_INDEX so it persists across subshells created by $()
FLOW_INDEX_FILE=$(mktemp)
echo 0 > "$FLOW_INDEX_FILE"
trap 'rm -f "$FLOW_INDEX_FILE"' EXIT

_flow_get_index() { cat "$FLOW_INDEX_FILE"; }
_flow_set_index() { echo "$1" > "$FLOW_INDEX_FILE"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --flow)
            FLOW_MODE=true
            IFS=',' read -r -a FLOW_QUEUE <<< "$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Wrapper for gum choose. In flow mode, consumes next queue value as 1-based index.
# In interactive mode, shows indexed options and strips index prefix from result.
flow_choose() {
    local options=("$@")
    if [ "$FLOW_MODE" = true ]; then
        local flow_index=$(_flow_get_index)
        if [ "$flow_index" -ge "${#FLOW_QUEUE[@]}" ]; then
            echo "Flow complete." >&2
            exit 0
        fi
        local idx="${FLOW_QUEUE[$flow_index]}"
        _flow_set_index $((flow_index + 1))
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#options[@]}" ]; then
            echo "Invalid flow index '$idx'. Valid range: 1-${#options[@]} for options: ${options[*]}" >&2
            exit 1
        fi
        local selected="${options[$((idx - 1))]}"
        echo "[flow] Selected: $selected" >&2
        echo "$selected"
    else
        local indexed_options=()
        for i in "${!options[@]}"; do
            indexed_options+=("$((i + 1)). ${options[$i]}")
        done
        local choice
        choice=$(gum choose "${indexed_options[@]}")
        # Strip the "N. " prefix
        echo "$choice" | sed 's/^[0-9]*\. //'
    fi
}

# Wrapper for gum confirm. In flow mode, consumes next queue value (y/n).
flow_confirm() {
    local prompt="$1"
    if [ "$FLOW_MODE" = true ]; then
        local flow_index=$(_flow_get_index)
        if [ "$flow_index" -ge "${#FLOW_QUEUE[@]}" ]; then
            echo "Flow complete." >&2
            exit 0
        fi
        local val="${FLOW_QUEUE[$flow_index]}"
        _flow_set_index $((flow_index + 1))
        echo "[flow] Confirm '$prompt': $val" >&2
        if [ "$val" = "y" ] || [ "$val" = "Y" ]; then
            return 0
        else
            return 1
        fi
    else
        gum confirm "$prompt"
    fi
}

# Wrapper for gum pager. In flow mode, uses cat to avoid blocking.
flow_pager() {
    if [ "$FLOW_MODE" = true ]; then
        cat
    else
        gum pager
    fi
}

run_prerequisite_commands(){
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo add glueops-platform https://helm.gpkg.io/platform
    helm repo add glueops-service https://helm.gpkg.io/service
    helm repo add glueops-project-template https://helm.gpkg.io/project-template
    helm repo add incubating-glueops-platform https://incubating-helm.gpkg.io/platform
    helm repo add incubating-glueops-service https://incubating-helm.gpkg.io/service
    helm repo add incubating-glueops-project-template https://incubating-helm.gpkg.io/project-template
    helm repo add projectcalico https://docs.tigera.io/calico/charts
    helm repo update
    helm plugin install https://github.com/databus23/helm-diff
}

check_codespace_version_match(){
    codespace_version=`yq '.versions[] | select(.name == "codespace_version") | .version' VERSIONS/glueops.yaml`
    if [ "$codespace_version" != $VERSION ]; then
        gum style --foreground 196 --bold "Current codespace version doesn't match with the desired: ${codespace_version}"
        if ! flow_confirm "Confirmation"; then
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

# Function to handle version selection and helm upgrade
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
        version=$(flow_choose "${versions[@]}" "Back")
        
        # Check if user wants to go back
        if [ "$version" = "Back" ]; then
            return
        fi
        echo "chosen version: $version for $chart_name"

        helm_diff_cmd="helm diff --color upgrade \"$component\" \"$chart_name\" --version \"$version\" -f \"$target_file\" -f \"$overrides_file\" -n \"$namespace\" --allow-unreleased"
        
        set -x
        eval "$helm_diff_cmd" | flow_pager # Execute the main helm diff command
        gum style --bold --foreground 212 "✅ Diff complete."
        set +x
        
        if ! flow_confirm "Apply upgrade"; then
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

handle_argocd() {
    if [ "$environment" = "production" ]; then
        argocd_version=`yq '.versions[] | select(.name == "argocd_helm_chart_version") | .version' VERSIONS/glueops.yaml`
    else
        argocd_version=($(helm search repo  argo/argo-cd --versions -o json | jq -r "limit(30; .[]).version" | paste -sd' ' -)) 
    fi
    while true; do
        unset helm_diff_cmd # Clear variables to avoid stale values
        local pre_commands=""
        local versions=() # Initialize versions array for each iteration
        local chosen_crd_version="" # To store the chosen CRD version
        # Show version selection
        versions=("${argocd_version[@]}")
        target_file="argocd.yaml"
        namespace="glueops-core"
        chart_name="argo/argo-cd"
        version=$(flow_choose "${versions[@]}" "Back")
        
        # Check if user wants to go back
        if [ "$version" = "Back" ]; then
            return
        fi
        echo "chosen version: $version for $chart_name"

        helm_diff_cmd="helm diff --color upgrade \"$component\" \"$chart_name\" --version \"$version\" -f \"$target_file\" -n \"$namespace\" --allow-unreleased"
        
        # New: Select ArgoCD CRD version if argocd is chosen
        gum style --bold --foreground 212 "Select ArgoCD App Version:"
        if [ "$environment" = "production" ]; then
            local argocd_crd_versions=`yq '.versions[] | select(.name == "argocd_app_version") | .version' VERSIONS/glueops.yaml`
        else
            local argocd_crd_versions=`v($(helm search repo argo/argo-cd --versions -o json | jq --arg chart_helm_version "$version" -r '.[] | select(.version == $chart_helm_version).app_version' | sed 's/^v//'))`
        fi
        chosen_crd_version=$(flow_choose "${argocd_crd_versions[@]}" "Back")
        pre_commands="kubectl apply -k \"https://github.com/argoproj/argo-cd/manifests/crds?ref=$chosen_crd_version\" && helm repo update"
        # Check if user wants to go back
        if [ "$chosen_crd_version" = "Back" ]; then
            return
        fi
        
        set -x
        eval "$helm_diff_cmd" | flow_pager # Execute the main helm diff command
        gum style --bold --foreground 212 "✅ Diff complete."
        set +x
        
        if ! flow_confirm "Apply upgrade"; then
            return
        fi
        
        # Running helm diff command
        gum style --bold --foreground 212 "The following commands will be executed:"
        
        # New: Execute pre_commands if defined
        if [ -n "$pre_commands" ] && [ -n "$chosen_crd_version" ]; then
            gum style --bold --foreground 212 "Executing pre-commands for $component:"
            set -x
            eval "$pre_commands"
            if [ $? -ne 0 ]; then
                gum style --bold --foreground 196 "❌ Pre-commands failed. Aborting diff."
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
    
    helm repo add projectcalico https://docs.tigera.io/calico/charts
    helm repo update

    set -x
    helm diff --color upgrade calico projectcalico/tigera-operator --version ${calico_version} --namespace tigera-operator -f calico.yaml --allow-unreleased | flow_pager
    gum style --bold --foreground 212 "✅ Diff complete."
    set +x

    if ! flow_confirm "Apply calico upgrade"; then
        return
    fi

    remove_daemonset='kubectl delete daemonset -n kube-system aws-node'
    gum style --bold --foreground 196 "Removing eks daemonset" 
    set -x
    ${remove_daemonset} || true
    
    gum style --bold --foreground 196 "Deploying calico helm chart ${calico_version}"
    
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
    local aws_component=$(flow_choose "calico" "eks-addons" "upgrade-eks-nodepools" "upgrade-kubernetes" "Exit")
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
        component=$(flow_choose "show_diff_table" "argocd" "glueops-platform" "aws" "inspect_pods" "Exit")

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
        component=$(flow_choose "argocd" "glueops-platform" "aws" "Exit")
        
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

        if [ "$component" = "argocd" ]; then
            handle_argocd
        fi

        
    done
}

check_codespace_version_match
run_prerequisite_commands

while true; do
    # Show main menu
    environment=$(flow_choose "dev" "production" "Exit")

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
