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
        gum style --foreground 212 --bold "Current codespace version doesn't match with the desired: ${codespace_version}"
        if ! gum confirm "Apply upgrade"; then
            return 1
        fi
    fi
}

upload_diff() {
    gum log --structured --level info "Uploading helm-diff output to ..."
}

show_diff_table(){
    command_args=("/workspaces/glueops/shared-tools/bin/python" "/usr/local/bin/script_captain_utils" "--write-diff-csv" "--base-path" $PWD)
    "${command_args[@]}"
    /usr/bin/gum table \
        --file ./captain_utils_diff.csv \
        --separator "," \
        --header.foreground "#FFAA00" \
        --header.bold \
        --cell.align "center" \
        --cell.border-foreground "63"
}

# Function to handle version selection and helm upgrade
handle_helm_upgrades() {
    local component=$1
    # Handle exit option
    if [ "$environment" = "production" ]; then
        argocd_version=`yq '.versions[] | select(.name == "argocd_helm_chart_version") | .version' VERSIONS/glueops.yaml`
        platform_version_string=`yq '.versions[] | select(.name == "glueops_platform_helm_chart_version") | .version' VERSIONS/glueops.yaml`
    else
        argocd_version=($(helm search repo  argo/argo-cd --versions -o json | jq -r "limit(30; .[]).version" | paste -sd' ' -)) 
        platform_version_string=$(gh release list --repo GlueOps/platform-helm-chart-platform --limit 10 --json tagName --jq '.[].tagName' | paste -sd' ' -)
    fi
    
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

            if [ -e "overrides.yaml" ]; then
                gum style --foreground 212 --bold "Overrides.yaml detected"
                overrides_file="overrides.yaml"
            else
                gum style --foreground 212 --bold "No Overrides.yaml detected"
                overrides_file="platform.yaml"
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

        helm_diff_cmd="helm diff --color upgrade \"$component\" \"$chart_name\" --version \"$version\" -f \"$target_file\" -f \"$overrides_file\" -n \"$namespace\" --allow-unreleased"
        
        if [ "$component" = "argocd" ]; then
            # New: Select ArgoCD CRD version if argocd is chosen
            gum style --bold "Select ArgoCD CRD Version:"
            local argocd_crd_versions=($(helm search repo argo/argo-cd --versions -o json | jq --arg chart_helm_version "$version" -r '.[] | select(.version == $chart_helm_version).app_version' | sed 's/^v//'))
            chosen_crd_version=$(gum choose "${argocd_crd_versions[@]}" "Back")
            pre_commands="kubectl apply -k \"https://github.com/argoproj/argo-cd/manifests/crds?ref=v$chosen_crd_version\" && helm repo update"
            # Check if user wants to go back
            if [ "$chosen_crd_version" = "Back" ]; then
                return
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
        gum style --bold "The following commands will be executed:"
        
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
        set -x
        helm upgrade --install "$component" "$chart_name" --version "$version" -f "$target_file" -f "$overrides_file" -n "$namespace" --create-namespace --skip-crds
        set +x
        return 
    done
}

handle_terraform_addons() {
    command_args=("/workspaces/glueops/shared-tools/bin/python" "/usr/local/bin/script_captain_utils" "--upgrade-addons" "--base-path" $PWD)
    "${command_args[@]}"
}
handle_terraform_nodepools() {
    command_args=("/workspaces/glueops/shared-tools/bin/python" "/usr/local/bin/script_captain_utils" "--upgrade-ami-version" "--base-path" $PWD)
    "${command_args[@]}"
}

handle_kubernetes_version() {
    command_args=("/workspaces/glueops/shared-tools/bin/python" "/usr/local/bin/script_captain_utils" "--upgrade-kubernetes-version" "--base-path" $PWD)
    "${command_args[@]}"
}


handle_aws_options(){
    local aws_component=$(gum choose "eks-addons" "upgrade-eks-nodepools" "upgrade-kubernetes" "Exit")
    # Handle exit option
    if [ "$aws_component" = "Exit" ]; then
        echo "Goodbye!"
        exit 0
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
        gum style --bold --foreground 212 "Showing diff table before proceeding"
        show_diff_table
    fi
    
    component=$(gum choose "argocd" "glueops-platform" "aws" "Exit")
    
    # Handle exit option
    if [ "$component" = "Exit" ]; then
        echo "Goodbye!"
        exit 0
    fi

    # 

    if [ "$component" = "aws" ]; then
        handle_aws_options
    fi

    if [ "$component" = "glueops-platform" ]; then
        handle_helm_upgrades $component
    fi

    if [ "$component" = "argocd" ]; then
        handle_helm_upgrades $component
    fi
  
done
