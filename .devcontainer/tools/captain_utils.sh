#!/bin/bash

BUCKET_NAME="helm-diff"
CAPTAIN_CLUSTER_NAME=$(basename $(pwd))

helm repo update

upload_diff() {
    gum log --structured --level info "Uploading helm-diff output to ..."
}

# Function to handle version selection and helm upgrade
handle_helm_upgrades() {
    local component=$1
    local argocd_version=($(helm search repo  argo/argo-cd --versions -o json | jq -r "limit(30; .[]).version" | paste -sd' ' -))   
    local platform_version_string=$(gh release list --repo GlueOps/platform-helm-chart-platform --limit 10 --json tagName --jq '.[].tagName' | paste -sd' ' -)

    while true; do
        unset pre_commands helm_diff_cmd # Clear variables to avoid stale values
        local versions=() # Initialize versions array for each iteration
        local target_file=""
        local namespace=""
        local chart_name=""
        local overrides_file=""
        local chosen_crd_version="" # To store the chosen CRD version
        # Show version selection
        if [ "$component" = "argocd" ]; then
            versions=("${argocd_version[@]}")
            target_file="argocd.yaml"
            namespace="glueops-core"
            chart_name="argo/argo-cd"
            overrides_file="argocd.yaml"

        elif [ "$component" = "glueops-platform" ]; then
            versions=(${platform_version_string})
            target_file="platform.yaml"
            overrides_file="platform.yaml"
            namespace="glueops-core"
            chart_name="glueops-platform/glueops-platform"

            if gum confirm "Use overrides" \
                --affirmative="Enabled" \
                --negative="Not Enabled"
            then
                overrides_file="overrides.yaml"
            fi
        else
            echo "Error: Invalid component '$component'. Please choose 'argocd' or 'glueops-platform'."
            return 1 # Exit if component is invalid
        fi
        version=$(gum choose "${versions[@]}" "Back")
        
        # Check if user wants to go back
        if [ "$version" = "Back" ]; then
            return
        fi
        echo "chosen version: $version for $chart_name"
        
        if [ "$component" = "argocd" ]; then
            # New: Select ArgoCD CRD version if argocd is chosen
            gum style --bold "Select ArgoCD CRD Version:"
            local argocd_crd_versions=($(helm search repo argo/argo-cd --versions -o json | jq --arg chart_helm_version "$version" -r '.[] | select(.version == $chart_helm_version).app_version' | sed 's/^v//'))
            chosen_crd_version=$(gum choose "${argocd_crd_versions[@]}" "Back")
            helm_diff_cmd+=" --skip-crds"
            pre_commands="kubectl apply -k \"https://github.com/argoproj/argo-cd/manifests/crds?ref=v$chosen_crd_version\" && helm repo update"
        fi

        # Check if user wants to go back
        if [ "$chosen_crd_version" = "Back" ]; then
            return
        fi

        # New: Execute pre_commands if defined
        if [ -n "$pre_commands" ] && [ -n "$chosen_crd_version" ]; then
            gum style --bold "Executing pre-commands for $component:"
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

        # Running helm diff command
        gum style --bold "The following commands will be executed:"

        helm_diff_cmd="helm diff --color upgrade \"$component\" \"$chart_name\" --version \"$version\" -f \"$target_file\" -f \"$overrides_file\" -n \"$namespace\" --allow-unreleased"

        set -x
        eval "$helm_diff_cmd | gum pager" # Execute the main helm diff command
        set +x
        gum style --bold --foreground 212 "✅ Diff complete."

        if ! gum confirm "Apply upgrade"; then
            return
        fi
        helm upgrade --install "$component" "$chart_name" --version "$version" -f "$target_file" -f "$overrides_file" -n "$namespace" --create-namespace --skip-crds
        return 
    done
}

handle_terraform_addons() {
    command_args=("python" "/usr/local/bin/main.py" "--upgrade-addons" "--base-path" $PWD)
    "${command_args[@]}"
}
handle_terraform_nodepools() {
    command_args=("python" "/usr/local/bin/main.py" "--upgrade-ami-version" "--base-path" $PWD)
    "${command_args[@]}"
}

handle_kubernetes_version() {
    command_args=("python" "/usr/local/bin/main.py" "--upgrade-kubernetes-version" "--base-path" $PWD)
    "${command_args[@]}"
}

# Main menu loop
while true; do
    # Show main menu
    component=$(gum choose "argocd" "glueops-platform" "eks-addons" "upgrade-eks-nodepools" "upgrade-kubernetes" "Exit")
    
    # Handle exit option
    if [ "$component" = "Exit" ]; then
        echo "Goodbye!"
        exit 0
    fi

    if [ "$component" = "eks-addons" ]; then
        handle_terraform_addons
    fi

    if [ "$component" = "upgrade-eks-nodepools" ]; then
        handle_terraform_nodepools
    fi
    
    if [ "$component" = "upgrade-kubernetes" ]; then
        handle_kubernetes_version
    fi

    if [ "$component" = "glueops-platform" ]; then
        handle_helm_upgrades $component
    fi

    if [ "$component" = "argocd" ]; then
        handle_helm_upgrades $component
    fi
  
done
