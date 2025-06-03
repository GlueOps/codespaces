#!/bin/bash

BUCKET_NAME="helm-diff"
CAPTAIN_CLUSTER_NAME=$(basename $(pwd))

upload_diff() {
    gum log --structured --level info "Uploading helm-diff output to ..."
}

# Function to handle version selection and helm upgrade
handle_version_selection() {
    local component=$1
    local argocd_version=($(helm search repo  argo/argo-cd --versions -o json | jq -r "limit(15; .[]).version" | paste -sd' ' -))   
    local platform_version_string=$(gh release list --repo GlueOps/platform-helm-chart-platform --limit 10 --json tagName --jq '.[].tagName' | paste -sd' ' -)
    
    
    while true; do
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
        fi
        version=$(gum choose "${versions[@]}" "Back")
        
        # Check if user wants to go back
        if [ "$version" = "Back" ]; then
            return
        fi
        echo "chosen version: $version for $chart_name"
        
        # Running helm diff command

        
        helm diff --color upgrade "$component" "$chart_name" --version "$version" -f $target_file -f $overrides_file -n $namespace | gum pager
        
        if ! gum confirm "Apply upgrade"; then
            return
        fi
        
        helm upgrade "$component" "$chart_name" --version "$version" -f $target_file -n $namespace

        # watch kubectl get apps -A | grep Progressing 

        upload_diff
        return 
    done
}

# Main menu loop
while true; do
    # Show main menu
    component=$(gum choose "argocd" "glueops-platform" "Exit")
    
    # Handle exit option
    if [ "$component" = "Exit" ]; then
        echo "Goodbye!"
        exit 0
    fi
    
    # Handle version selection for chosen component
    handle_version_selection "$component"
done