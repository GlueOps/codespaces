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

# menu item "crds" — run BEFORE argocd and AGAIN AFTER argocd (second run is a no-op unless the argocd release removed a CRD).
# Never propagates a non-zero status into the `set -e` menu loop.
handle_crds() {
    local v
    if [ ! -x "$CAPTAIN_UTILS_CRDS" ]; then
        gum style --foreground 196 "❌ $CAPTAIN_UTILS_CRDS is missing or not executable — rebuild the codespace image"; return 0
    fi
    if ! v=$(environment="$environment" "$CAPTAIN_UTILS_CRDS" target-version); then gum style --foreground 196 "❌ could not determine the platform-crds version"; return 0; fi
    if [ "$v" = "Back" ]; then return 0; fi
    if ! environment="$environment" "$CAPTAIN_UTILS_CRDS" apply "$v"; then gum style --foreground 196 "platform-crds $v NOT applied"; fi
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
        version=$(gum choose "${versions[@]}" "Back")
        
        # Check if user wants to go back
        if [ "$version" = "Back" ]; then
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
        
        # ArgoCD's CRDs are no longer applied here: they are part of the platform-crds bundle (menu item "crds").
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
