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
# captain_utils.sh runs with `set -e -u -o pipefail`; every non-zero exit below is handled explicitly, and
# handle_crds never propagates a non-zero status into the menu loop.
CRDS_CHART="${CRDS_CHART:-oci://ghcr.repo.gpkg.io/glueops/platform-crds}"   # mirror of ghcr.io/glueops/platform-crds
CRDS_FIELD_MANAGER="glueops-platform-crds"

crds_valid_version() {   # $1 = version; rejects empty/garbage (an empty --version makes helm pull LATEST)
    if [[ ! "${1:-}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        gum style --foreground 196 "❌ no/invalid platform_crds_version ('${1:-}') — run 'terraform apply' on the captain repo first" >&2
        return 1
    fi
}

crds_target_version() {   # prints a version or "Back"; non-zero when it cannot determine one
    local tags
    if [ "$environment" = "production" ]; then
        yq '.versions[] | select(.name == "platform_crds_version") | .version' VERSIONS/glueops.yaml
    else
        tags=$(gh release list --repo GlueOps/platform-crds --limit 10 --json tagName --jq '.[].tagName' | paste -sd' ' -) || return 1
        [ -n "$tags" ] || return 1
        gum choose $tags "Back"
    fi
}

crds_fetch() {   # $1 = version, $2 = work dir; prints the path of the rendered bundle (written atomically)
    local v=${1#v} out="$2/platform-crds-${1}.yaml"
    if ! helm show crds "$CRDS_CHART" --version "$v" > "$out.tmp" 2>"$2/fetch.err"; then
        cat "$2/fetch.err" >&2; return 1
    fi
    if [ "$(grep -c '^kind: CustomResourceDefinition' "$out.tmp")" -eq 0 ]; then
        gum style --foreground 196 "❌ platform-crds $1 rendered no CRDs" >&2; return 1
    fi
    mv "$out.tmp" "$out" && echo "$out"
}

crds_names() { yq -N 'select(.kind=="CustomResourceDefinition") | .metadata.name' "$1"; }

# Live CRD JSON for the bundle's CRDs only (one API call), written to a file (too large for argv/variables).
crds_live_json() {   # $1 = bundle file, $2 = output file
    local names_json; names_json=$(crds_names "$1" | jq -R . | jq -sc .) || return 1
    kubectl get crd -o json | jq -c --argjson names "$names_json" '[.items[] | select(.metadata.name as $n | $names | index($n))]' > "$2"
}

# A stored API version that the new bundle no longer declares makes the API server reject the update
# ("must remain in spec.versions until a storage migration"). Detect it before applying and name the fix.
crds_storedversions_check() {   # $1 = bundle file, $2 = live json file
    local bad
    bad=$(yq -N -o=json -I0 'select(.kind=="CustomResourceDefinition") | {"name": .metadata.name, "versions": [.spec.versions[].name], "served": [.spec.versions[] | select(.served==true) | .name]}' "$1" \
        | jq -rs --slurpfile livef "$2" '$livef[0] as $live |
            map({(.name): .}) | add as $b
            | $live[] | .metadata.name as $n | select($b[$n] != null)
            | (.status.storedVersions // [])[] as $sv
            | if ($b[$n].versions | index($sv)) == null then "ERROR \($n) stores \($sv), which platform-crds no longer defines"
              elif ($b[$n].served | index($sv)) == null then "WARN  \($n) stores \($sv), which is no longer served — migrate storage before the next bump"
              else empty end') || { gum style --foreground 196 "❌ storedVersions check failed"; return 1; }
    if grep -q '^ERROR' <<<"$bad"; then
        gum style --foreground 196 --bold "❌ storage-version migration required before this bundle can be applied:"
        grep '^ERROR' <<<"$bad" | sed 's/^ERROR /  /'
        echo "  fix (per CRD):  kubectl get <plural.group> -A -o json | kubectl replace -f -   # rewrites objects at the current storage version"
        echo "                  kubectl patch crd <name> --subresource=status --type=merge -p '{\"status\":{\"storedVersions\":[\"<remaining>\"]}}'"
        return 1
    fi
    grep '^WARN' <<<"$bad" | sed 's/^WARN  /  ⚠ /' || true
}

# A CRD still being deleted (e.g. the Gate CRD right after the argocd release dropped it) must be gone before we re-create it.
crds_wait_terminating() {   # $1 = live json file
    local dying; dying=$(jq -r '.[] | select(.metadata.deletionTimestamp != null) | .metadata.name' "$1") || return 1
    if [ -n "$dying" ]; then
        gum style --foreground 212 "Waiting for terminating CRD(s) to disappear: $(echo $dying)"
        kubectl wait --for=delete crd $dying --timeout=120s >/dev/null || return 1
    fi
}

# Strip stray ArgoCD tracking metadata from the bundle's CRDs (belt-and-braces: Argo has never stamped CRDs —
# the repo-server skips kube.IsCRD — but a tracked CRD would be auto-pruned once it leaves an app's desired state).
# NOTE: kubectl.kubernetes.io/last-applied-configuration is deliberately NOT stripped here: kubectl's server-side
# apply uses it to migrate client-side-apply ownership into our field manager. Leftovers are stripped after the apply.
crds_strip_argo_tracking() {   # $1 = live json file
    local ann lab
    ann=$(jq -r '.[] | select(.metadata.annotations["argocd.argoproj.io/tracking-id"] != null) | .metadata.name' "$1") || return 1
    lab=$(jq -r '.[] | select(.metadata.labels["argocd.argoproj.io/instance"] != null) | .metadata.name' "$1") || return 1
    if [ -n "$ann" ]; then
        gum style --foreground 212 "Removing ArgoCD tracking annotation from: $(echo $ann)"
        kubectl annotate crd $ann argocd.argoproj.io/tracking-id- >/dev/null || return 1
    fi
    if [ -n "$lab" ]; then
        gum style --foreground 212 "Removing ArgoCD instance label from: $(echo $lab)"
        kubectl label crd $lab argocd.argoproj.io/instance- >/dev/null || return 1
    fi
}

crds_strip_last_applied() {   # $1 = bundle file, $2 = work dir — leftovers after apply (objects kubectl did not migrate)
    local left
    crds_live_json "$1" "$2/live-after.json" || return 1
    left=$(jq -r '.[] | select(.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] != null) | .metadata.name' "$2/live-after.json") || return 1
    if [ -n "$left" ]; then
        kubectl annotate crd $left kubectl.kubernetes.io/last-applied-configuration- >/dev/null || return 1
    fi
}

crds_summary() {   # $1 = diff output — one aggregate line: a CRD that does not exist yet diffs from an empty file (single "@@ -0,0" hunk)
    local new chg
    new=$(grep -c '^@@ -0,0 ' <<<"$1" || true)
    chg=$(grep -c '^diff -u -N ' <<<"$1" || true)
    echo "  $new new, $((chg-new)) changed"
}

# diff -> confirm -> server-side apply (ALWAYS, also when the diff is empty, so field ownership lands on our manager)
# -> wait Established -> strip leftovers -> assert ownership. Returns 0 on success or operator decline.
crds_apply() {   # $1 = version
    local v=$1 wd file difftxt rc=0 total unowned
    crds_valid_version "$v" || return 1
    wd=$(mktemp -d "${TMPDIR:-/tmp}/platform-crds.XXXXXX") || return 1
    file=$(crds_fetch "$v" "$wd") || return 1
    total=$(crds_names "$file" | wc -l)
    crds_live_json "$file" "$wd/live.json" || return 1
    crds_storedversions_check "$file" "$wd/live.json" || return 1
    if difftxt=$(kubectl diff --server-side --force-conflicts --field-manager="$CRDS_FIELD_MANAGER" -f "$file" 2>&1); then rc=0; else rc=$?; fi
    if [ "$rc" -gt 1 ]; then echo "$difftxt" | tail -20; gum style --foreground 196 "❌ kubectl diff failed"; return 1; fi
    if [ "$rc" -eq 1 ]; then
        gum style --bold --foreground 212 "CRD changes for platform-crds $v ($total CRDs in bundle):"; crds_summary "$difftxt"
        echo "$difftxt" | gum pager
        if [ "${CRDS_AUTO_CONFIRM:-}" != "yes" ]; then
            if ! gum confirm "Apply platform-crds $v?"; then gum style --foreground 212 "Skipped platform-crds $v"; return 0; fi
        fi
    else
        gum style --foreground 212 "No CRD content changes for platform-crds $v ($total CRDs) — applying to record ownership"
    fi
    crds_strip_argo_tracking "$wd/live.json" || return 1
    crds_wait_terminating "$wd/live.json" || return 1
    echo "kubectl apply --server-side --force-conflicts --field-manager=$CRDS_FIELD_MANAGER -f $file"
    if ! kubectl apply --server-side --force-conflicts --field-manager="$CRDS_FIELD_MANAGER" -f "$file" | tail -3; then
        gum style --foreground 196 "❌ CRD apply failed"; return 1
    fi
    if ! kubectl wait --for=condition=Established crd $(crds_names "$file" | xargs) --timeout=120s > /dev/null; then
        gum style --foreground 196 "❌ some CRDs did not become Established"; return 1
    fi
    crds_strip_last_applied "$file" "$wd" || return 1
    unowned=$(jq -r --arg m "$CRDS_FIELD_MANAGER" '.[] | select([.metadata.managedFields[]? | select(.manager==$m and .operation=="Apply")] | length == 0) | .metadata.name' \
        <(kubectl get crd --show-managed-fields -o json | jq -c --argjson names "$(crds_names "$file" | jq -R . | jq -sc .)" '[.items[] | select(.metadata.name as $n | $names | index($n))]')) \
        || { gum style --foreground 196 "❌ ownership check failed"; return 1; }
    if [ -n "$unowned" ]; then gum style --foreground 196 "❌ not owned by $CRDS_FIELD_MANAGER after apply: $(echo $unowned)"; return 1; fi
    gum style --foreground 212 "✅ $total CRDs Established and owned by $CRDS_FIELD_MANAGER at platform-crds $v"
}

# menu item "crds" — run BEFORE argocd and AGAIN AFTER argocd (second run is a no-op unless the argocd release removed a CRD)
handle_crds() {
    local v
    if ! v=$(crds_target_version); then gum style --foreground 196 "❌ could not determine the platform-crds version"; return 0; fi
    if [ "$v" = "Back" ]; then return 0; fi
    if ! crds_apply "$v"; then gum style --foreground 196 "platform-crds $v NOT applied"; fi
    return 0
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
