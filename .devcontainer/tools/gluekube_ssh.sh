#!/bin/bash
set -euo pipefail

# Config
CONFIG_DIR="$HOME/.config/autoglue-ssh"
CONFIG_FILE="$CONFIG_DIR/config.json"
DEFAULT_ENDPOINT="https://autoglue.glueopshosted.com/api/v1"

# Colors
GUM_CHOOSE_HEADER="Select an option"

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# API helper functions
api_call() {
    local method="$1"
    local path="$2"
    local org_id="${3:-}"
    
    local headers=(-H "X-API-KEY: $API_KEY")
    [[ -n "$org_id" ]] && headers+=(-H "X-Org-ID: $org_id")
    
    curl -s -X "$method" "${headers[@]}" "$API_ENDPOINT$path"
}

validate_api_key() {
    local response
    response=$(api_call GET "/me" 2>&1)
    echo "$response" | jq -e '.id' >/dev/null 2>&1
}

# Profile management
load_profiles() {
    if [[ -f "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE"
    else
        echo '{"profiles":[]}'
    fi
}

save_profiles() {
    echo "$1" > "$CONFIG_FILE"
}

list_profile_names() {
    load_profiles | jq -r '.profiles[].name'
}

get_profile() {
    local name="$1"
    load_profiles | jq -r ".profiles[] | select(.name == \"$name\")"
}

add_profile() {
    local name="$1"
    local api_key="$2"
    local endpoint="$3"
    
    local profiles
    profiles=$(load_profiles)
    
    # Add new profile
    profiles=$(echo "$profiles" | jq --arg name "$name" --arg key "$api_key" --arg endpoint "$endpoint" \
        '.profiles += [{"name": $name, "api_key": $key, "api_endpoint": $endpoint}]')
    
    save_profiles "$profiles"
}

delete_profile() {
    local name="$1"
    local profiles
    profiles=$(load_profiles)
    profiles=$(echo "$profiles" | jq --arg name "$name" '.profiles |= map(select(.name != $name))')
    save_profiles "$profiles"
}

# Profile UI
profile_menu() {
    while true; do
        gum style --border rounded --padding "1 2" --margin "1" \
            "AutoGlue SSH - Profile Manager"
        
        local choice
        choice=$(gum choose --header="What would you like to do?" \
            "Select Profile" \
            "Add New Profile" \
            "Delete Profile" \
            "Quit")
        
        case "$choice" in
            "Select Profile")
                select_profile
                if [[ -n "${SELECTED_PROFILE:-}" ]]; then
                    return 0
                fi
                ;;
            "Add New Profile")
                add_profile_interactive
                ;;
            "Delete Profile")
                delete_profile_interactive
                ;;
            "Quit")
                exit 0
                ;;
        esac
    done
}

select_profile() {
    local profiles
    profiles=$(list_profile_names)
    
    if [[ -z "$profiles" ]]; then
        gum style --foreground 208 "No profiles configured. Please add one first."
        sleep 2
        return
    fi
    
    local name
    name=$(echo "$profiles" | gum choose --header="Select a profile:")
    
    if [[ -n "$name" ]]; then
        SELECTED_PROFILE="$name"
        local profile
        profile=$(get_profile "$name")
        API_KEY=$(echo "$profile" | jq -r '.api_key')
        API_ENDPOINT=$(echo "$profile" | jq -r '.api_endpoint')
    fi
}

add_profile_interactive() {
    gum style --border rounded --padding "1 2" "Add New Profile"
    
    local name
    name=$(gum input --placeholder "Profile name (e.g., production)")
    
    [[ -z "$name" ]] && return
    
    local api_key
    api_key=$(gum input --password --placeholder "API Key")
    
    [[ -z "$api_key" ]] && return
    
    # Endpoint selection with presets
    local endpoint_choice
    endpoint_choice=$(gum choose --header="Select API endpoint:" \
        "https://autoglue.glueopshosted.com/api/v1 (Prod)" \
        "https://autoglue.glueopshosted.rocks/api/v1 (Nonprod/Dev)" \
        "Custom (enter URL)")
    
    local endpoint
    case "$endpoint_choice" in
        "https://autoglue.glueopshosted.com/api/v1 (Prod)")
            endpoint="https://autoglue.glueopshosted.com/api/v1"
            ;;
        "https://autoglue.glueopshosted.rocks/api/v1 (Nonprod/Dev)")
            endpoint="https://autoglue.glueopshosted.rocks/api/v1"
            ;;
        "Custom (enter URL)")
            endpoint=$(gum input --placeholder "API Endpoint URL (e.g., https://example.com/api/v1)")
            [[ -z "$endpoint" ]] && return
            ;;
        *)
            return
            ;;
    esac
    
    # Validate
    gum spin --spinner dot --title "Validating API key..." -- sleep 1
    
    API_KEY="$api_key"
    API_ENDPOINT="$endpoint"
    
    if validate_api_key; then
        add_profile "$name" "$api_key" "$endpoint"
        gum style --foreground 82 "✓ Profile '$name' added successfully!"
        sleep 2
    else
        gum style --foreground 196 "✗ API key validation failed!"
        sleep 2
    fi
}

delete_profile_interactive() {
    local profiles
    profiles=$(list_profile_names)
    
    if [[ -z "$profiles" ]]; then
        gum style --foreground 208 "No profiles to delete."
        sleep 2
        return
    fi
    
    local name
    name=$(echo "$profiles" | gum choose --header="Select profile to delete:")
    
    if [[ -n "$name" ]]; then
        if gum confirm "Delete profile '$name'?"; then
            delete_profile "$name"
            gum style --foreground 82 "✓ Profile deleted"
            sleep 1
        fi
    fi
}

# Main navigation
browse_infrastructure() {
    # Organization selection loop
    while true; do
        # List orgs
        gum spin --spinner dot --title "Loading organizations..." -- sleep 0.5
        
        local orgs
        orgs=$(api_call GET "/orgs")
        
        local org_choices
        org_choices=$(echo "$orgs" | jq -r '.[] | "\(.name)|\(.id)"')
        
        if [[ -z "$org_choices" ]]; then
            gum style --foreground 196 "No organizations found"
            exit 1
        fi
        
        local org_selection
        org_selection=$(echo -e "$(echo "$org_choices" | cut -d'|' -f1)\n◀ Back" | gum choose --header="Select organization:")
        
        if [[ -z "$org_selection" ]]; then
            return
        fi
        
        [[ "$org_selection" == "◀ Back" ]] && return
        
        local org_id
        org_id=$(echo "$org_choices" | grep "^$org_selection|" | cut -d'|' -f2)
        
        # Cluster selection loop
        while true; do
            # List clusters
            gum spin --spinner dot --title "Loading clusters..." -- sleep 0.5
            
            local clusters
            clusters=$(api_call GET "/clusters" "$org_id")
            
            local cluster_choices
            cluster_choices=$(echo "$clusters" | jq -r '.[] | "\(.name)|\(.id)"')
            
            if [[ -z "$cluster_choices" ]]; then
                gum style --foreground 196 "No clusters found"
                sleep 2
                break
            fi
            
            local cluster_selection
            cluster_selection=$(echo -e "$(echo "$cluster_choices" | cut -d'|' -f1)\n◀ Back" | gum choose --header="Select cluster:")
            
            if [[ -z "$cluster_selection" ]]; then
                break
            fi
            
            [[ "$cluster_selection" == "◀ Back" ]] && break
            
            local cluster_id
            cluster_id=$(echo "$cluster_choices" | grep "^$cluster_selection|" | cut -d'|' -f2)
    
    # Get full cluster details
    gum spin --spinner dot --title "Loading servers..." -- sleep 0.5
    
    local cluster
    cluster=$(api_call GET "/clusters/$cluster_id" "$org_id")
    
    # Get bastion
    local bastion_ip
    bastion_ip=$(echo "$cluster" | jq -r '.bastion_server.public_ip_address // empty')
    
    if [[ -z "$bastion_ip" ]]; then
        gum style --foreground 196 "No bastion server found for this cluster"
        return
    fi
    
    # Load bastion SSH key to agent
    local bastion_key_id
    bastion_key_id=$(echo "$cluster" | jq -r '.bastion_server.ssh_key_id // empty')
    
    if [[ -n "$bastion_key_id" ]]; then
        # Check if ssh-agent is running (exit code 2 = not running, 0/1 = running)
        local agent_status=0
        ssh-add -l >/dev/null 2>&1 || agent_status=$?
        if [[ $agent_status -eq 2 ]]; then
            gum style --foreground 208 "⚠ ssh-agent not running. Starting..."
            eval $(ssh-agent) > /dev/null
            gum style --foreground 82 "✓ ssh-agent started"
            sleep 1
        fi
        
        gum spin --spinner dot --title "Loading bastion SSH key..." -- sleep 0.5
        local key_data
        key_data=$(api_call GET "/ssh/$bastion_key_id?reveal=true" "$org_id")
        local private_key
        private_key=$(echo "$key_data" | jq -r '.private_key')
        
        # Add to ssh-agent
        if echo "$private_key" | ssh-add - 2>&1 | grep -q "Identity added"; then
            gum style --foreground 82 "✓ Bastion key loaded to ssh-agent"
            sleep 1
        else
            gum style --foreground 208 "⚠ Warning: Could not add key to ssh-agent (continuing anyway)"
            sleep 2
        fi
    fi
    
    # List servers from all node pools AND include bastion
    local servers=""
    
    # Add bastion server first
    local bastion_hostname
    bastion_hostname=$(echo "$cluster" | jq -r '.bastion_server.hostname // empty')
    if [[ -n "$bastion_hostname" ]]; then
        local bastion_status
        bastion_status=$(echo "$cluster" | jq -r '.bastion_server.status // "ready"')
        servers="BASTION|$bastion_hostname|$bastion_status|$bastion_ip"
    fi
    
    # Add node pool servers
    local node_servers
    node_servers=$(echo "$cluster" | jq -r '.node_pools[].servers[] | "\(.role | ascii_upcase)|\(.hostname)|\(.status)|\(.public_ip_address)"' 2>/dev/null || true)
    
    if [[ -n "$node_servers" ]]; then
        if [[ -n "$servers" ]]; then
            servers="$servers"$'\n'"$node_servers"
        else
            servers="$node_servers"
        fi
    fi
    
    if [[ -z "$servers" ]]; then
        gum style --foreground 196 "No servers found"
        sleep 2
        continue
    fi
    
    # Mode selection loop
    while true; do
        local mode
        mode=$(gum choose --header="What would you like to do?" \
            "🔗 SSH to servers" \
            "📡 Port forward to master (6443)" \
            "⚙️ Setup ~/.kube/config" \
            "◀ Back")
        
        # Handle escape or empty selection
        if [[ -z "$mode" ]]; then
            break
        fi
        
        case "$mode" in
            "🔗 SSH to servers")
                ssh_mode "$cluster_id" "$bastion_ip" "$servers"
                ;;
            "📡 Port forward to master (6443)")
                kubectl_mode "$cluster_id" "$bastion_ip" "$servers"
                ;;
            "⚙️ Setup ~/.kube/config")
                kubeconfig_mode "$cluster_id" "$bastion_ip" "$servers"
                ;;
            "◀ Back")
                break
                ;;
        esac
    done
        done
    done
}

# SSH mode - show all servers, connect directly when selected
ssh_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    
    # Server selection loop
    while true; do
        # Format for display
        local server_list
        server_list=$(echo "$servers" | awk -F'|' '{printf "[%s] %s (%s)\n", $1, $2, $3}')
        
        local server_selection
        server_selection=$(echo -e "$server_list\n◀ Back" | gum choose --header="Select server:")
        
        # Handle escape or empty selection
        if [[ -z "$server_selection" ]]; then
            return
        fi
        
        [[ "$server_selection" == "◀ Back" ]] && return
        [[ -z "$server_selection" ]] && continue
        
        # Extract hostname
        local hostname
        hostname=$(echo "$server_selection" | sed -n 's/.*] \([^ ]*\).*/\1/p')
        
        # Extract role
        local role
        role=$(echo "$server_selection" | sed -n 's/\[\([^]]*\)\].*/\1/p')
        
        # Get the private IP for this server
        local target_ip
        target_ip=$(echo "$servers" | grep "|$hostname|" | cut -d'|' -f4)
        
        # Connect directly - after exit, returns to server list
        connect_ssh "$bastion_ip" "$cluster_id" "$hostname" "$role" "$target_ip"
    done
}

# kubectl mode - show only master nodes, port forward directly when selected
kubectl_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    
    # Filter to only master nodes
    local master_servers
    master_servers=$(echo "$servers" | grep "^MASTER|")
    
    if [[ -z "$master_servers" ]]; then
        gum style --foreground 196 "No master nodes found"
        sleep 2
        return
    fi
    
    # Master selection loop
    while true; do
        # Format for display
        local server_list
        server_list=$(echo "$master_servers" | awk -F'|' '{printf "[%s] %s (%s)\n", $1, $2, $3}')
        
        local server_selection
        server_selection=$(echo -e "$server_list\n◀ Back" | gum choose --header="Select master node for kubectl:")
        
        # Handle escape or empty selection
        if [[ -z "$server_selection" ]]; then
            return
        fi
        
        [[ "$server_selection" == "◀ Back" ]] && return
        [[ -z "$server_selection" ]] && continue
        
        # Extract hostname
        local hostname
        hostname=$(echo "$server_selection" | sed -n 's/.*] \([^ ]*\).*/\1/p')
        
        # Get the private IP for this server
        local target_ip
        target_ip=$(echo "$master_servers" | grep "|$hostname|" | cut -d'|' -f4)
        
        # Port forward directly - after Ctrl+C, returns to master list
        port_forward "$bastion_ip" "$cluster_id" "$hostname" "$target_ip"
    done
}

# kubeconfig mode - copy admin.conf from master to ~/.kube/config
kubeconfig_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    
    # Filter to only master nodes
    local master_servers
    master_servers=$(echo "$servers" | grep "^MASTER|")
    
    if [[ -z "$master_servers" ]]; then
        gum style --foreground 196 "No master nodes found"
        sleep 2
        return
    fi
    
    gum style --border rounded --padding "1 2" \
        "Setup ~/.kube/config" \
        "" \
        "This will copy /etc/kubernetes/admin.conf from a master node"
    
    echo ""
    
    # Format for display
    local server_list
    server_list=$(echo "$master_servers" | awk -F'|' '{printf "[%s] %s (%s)\n", $1, $2, $3}')
    
    local server_selection
    server_selection=$(echo -e "$server_list\n◀ Back" | gum choose --header="Select master node to get kubeconfig from:")
    
    # Handle escape or empty selection
    if [[ -z "$server_selection" ]] || [[ "$server_selection" == "◀ Back" ]]; then
        return
    fi
    
    # Extract hostname
    local hostname
    hostname=$(echo "$server_selection" | sed -n 's/.*] \([^ ]*\).*/\1/p')
    
    # Create ~/.kube directory if it doesn't exist
    mkdir -p ~/.kube
    
    gum spin --spinner dot --title "Copying admin.conf from $hostname..." -- sleep 0.5
    
    # Copy the file through bastion using double-hop SCP
    # First copy from master to bastion, then from bastion to local
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t cluster@"$bastion_ip" \
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -F ~/.ssh/autoglue/cluster-$cluster_id.config $hostname \
        'sudo cat /etc/kubernetes/admin.conf'" > ~/.kube/config 2>/dev/null; then
        
        gum style --foreground 82 "✓ Kubeconfig copied to ~/.kube/config"
        sleep 1
        
        # Update the server URL to localhost:6443
        gum spin --spinner dot --title "Updating server URL..." -- sleep 0.5
        
        if kubectl config set-cluster "kubernetes" --server=https://127.0.0.1:6443 >/dev/null 2>&1; then
            gum style --foreground 82 "✓ Server URL updated to https://127.0.0.1:6443"
            gum style --foreground 208 "
⚠ Remember to port forward to a master node before using kubectl!"
            sleep 3
        else
            gum style --foreground 208 "⚠ Warning: Could not update server URL. You may need to do it manually."
            sleep 2
        fi
    else
        gum style --foreground 196 "✗ Failed to copy kubeconfig"
        sleep 2
    fi
}

# SSH Functions
connect_ssh() {
    local bastion_ip="$1"
    local cluster_id="$2"
    local hostname="$3"
    local role="${4:-}"
    local target_ip="${5:-}"
    
    # Check if this IS the bastion
    if [[ "$role" == "BASTION" ]]; then
        gum style --border rounded --padding "1 2" \
            "Connecting to bastion: $hostname"
        
        echo ""
        
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null cluster@"$bastion_ip"
    else
        gum style --border rounded --padding "1 2" \
            "Connecting to $hostname via $bastion_ip"
        
        echo ""
        
        # Use SSH config file on bastion
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t cluster@"$bastion_ip" \
            "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -F ~/.ssh/autoglue/cluster-$cluster_id.config $hostname"
    fi
}

port_forward() {
    local bastion_ip="$1"
    local cluster_id="$2"
    local hostname="$3"
    local target_ip="${4:-}"
    
    local port="6443"
    
    gum style --border rounded --padding "1 2" \
        "Port forwarding localhost:$port → $hostname:6443" \
        "" \
        "Press Ctrl+C to stop"
    
    echo ""
    
    # Double hop: laptop->bastion->target, both with -L forwarding
    # Use SSH config file on bastion which has the correct keys
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ExitOnForwardFailure=yes \
        -L "$port:localhost:$port" -t cluster@"$bastion_ip" \
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -N -L $port:localhost:6443 -F ~/.ssh/autoglue/cluster-$cluster_id.config $hostname"
}

# Main
main() {
    # Check for --profile flag
    if [[ "${1:-}" == "--profile" && -n "${2:-}" ]]; then
        SELECTED_PROFILE="$2"
        local profile
        profile=$(get_profile "$2")
        
        if [[ -z "$profile" ]]; then
            gum style --foreground 196 "Profile '$2' not found"
            exit 1
        fi
        
        API_KEY=$(echo "$profile" | jq -r '.api_key')
        API_ENDPOINT=$(echo "$profile" | jq -r '.api_endpoint')
    else
        # Interactive profile selection
        profile_menu
    fi
    
    # Browse infrastructure - auto-loop, Ctrl+C to quit
    while true; do
        browse_infrastructure
    done
}

main "$@"
