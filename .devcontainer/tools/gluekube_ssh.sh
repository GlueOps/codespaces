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

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# ProxyCommand to reach a node through the bastion. Tunnels with -W and auths
# both hops from the local ssh-agent, so it works with AllowAgentForwarding no.
bastion_proxy() {
    local bastion_ip="$1"
    echo "ssh ${SSH_OPTS[*]} -W %h:%p cluster@$bastion_ip"
}

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

# Get GitHub org based on API endpoint
# glueopshosted.com -> production-captains
# Everything else (glueopshosted.rocks, custom) -> development-captains
get_gh_org() {
    if [[ "$API_ENDPOINT" == *"glueopshosted.com"* ]]; then
        echo "production-captains"
    else
        echo "development-captains"
    fi
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
    echo "Validating API key..."
    
    API_KEY="$api_key"
    API_ENDPOINT="$endpoint"
    
    if validate_api_key; then
        add_profile "$name" "$api_key" "$endpoint"
        gum style --foreground 82 "✓ Profile '$name' added successfully!"
        sleep 1
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
        clear
        # List orgs
        local orgs
        orgs=$(api_call GET "/orgs")
        
        local org_choices
        org_choices=$(echo "$orgs" | jq -r '.[] | "\(.name)|\(.id)"')
        
        if [[ -z "$org_choices" ]]; then
            gum style --foreground 196 "No organizations found"
            exit 1
        fi
        
        local org_selection
        org_selection=$(echo -e "$(echo "$org_choices" | cut -d'|' -f1)\n◀ Back" | gum choose --header="Select organization:" || true)
        
        # Handle ESC or Back
        if [[ -z "$org_selection" ]] || [[ "$org_selection" == "◀ Back" ]]; then
            return
        fi
        
        local org_id
        org_id=$(echo "$org_choices" | grep "^$org_selection|" | cut -d'|' -f2)
        
        # Get all GitHub repos from the organization that match the selected org suffix
        local gh_org
        gh_org=$(get_gh_org)
        local all_repos=""
        if command -v gh &> /dev/null; then
            all_repos=$(gh repo list "$gh_org" --limit 200 --json name -q '.[].name' 2>/dev/null | grep "\\.${org_selection}$" || true)
        fi
        
        # Repository/Cluster selection loop
        while true; do
            clear
            # If no repos found, fall back to showing clusters
            if [[ -z "$all_repos" ]]; then
                echo "No GitHub repositories found for this organization"
                break
            fi
            
            # Show repository selection menu
            local repo_selection
            repo_selection=$(echo -e "$all_repos\n◀ Back" | gum choose --header="Select cluster:" || true)
            
            # Handle ESC or Back
            if [[ -z "$repo_selection" ]] || [[ "$repo_selection" == "◀ Back" ]]; then
                break
            fi
            
            local cluster_selection="$repo_selection"
            local matched_repo="$repo_selection"
            
            # List clusters to find matching cluster ID
            local clusters
            clusters=$(api_call GET "/clusters" "$org_id")
            
            local cluster_choices
            cluster_choices=$(echo "$clusters" | jq -r '.[] | "\(.name)|\(.id)"' || true)
            
            local cluster_id
            cluster_id=$(echo "$cluster_choices" | grep "^${cluster_selection}|" | cut -d'|' -f2 || true)
            
            # Check if cluster exists in AutoGlue
            if [[ -z "$cluster_id" ]]; then
                # Cluster doesn't exist in AutoGlue, only show clone repo option
                if [[ -n "$matched_repo" ]]; then
                    local mode
                    mode=$(gum choose --header="What would you like to do?" "📦 Clone Captain Repository ($matched_repo)" "◀ Back" || true)
                    
                    case "$mode" in
                        📦*)
                            clone_repo_mode "$matched_repo" "$(get_gh_org)"
                            ;;
                        *)
                            continue
                            ;;
                    esac
                else
                    echo "This cluster is not managed in AutoGlue and has no GitHub repo"
                fi
                continue
            fi
    
            # Get full cluster details
            local cluster
            cluster=$(api_call GET "/clusters/$cluster_id" "$org_id")
    
            # Get cluster status
            local cluster_status
            cluster_status=$(echo "$cluster" | jq -r '.status // "unknown"')
    
            # Get bastion
            local bastion_ip
            bastion_ip=$(echo "$cluster" | jq -r '.bastion_server.public_ip_address // empty')
            
            # Get bastion SSH key ID for later use
            local bastion_key_id
            bastion_key_id=$(echo "$cluster" | jq -r '.bastion_server.ssh_key_id // empty')
            
            # List servers from all node pools AND include bastion
            local servers=""
            
            # Add bastion server first
            local bastion_hostname
            bastion_hostname=$(echo "$cluster" | jq -r '.bastion_server.hostname // empty')
            if [[ -n "$bastion_hostname" ]]; then
                local bastion_status
                bastion_status=$(echo "$cluster" | jq -r '.bastion_server.status // "ready"')
                local bastion_private_ip
                bastion_private_ip=$(echo "$cluster" | jq -r '.bastion_server.private_ip_address // "N/A"')
                servers="BASTION|$bastion_hostname|$bastion_status|$bastion_ip|$bastion_private_ip|$bastion_key_id"
            fi
            
            # Add node pool servers
            local node_servers
            node_servers=$(echo "$cluster" | jq -r '.node_pools[].servers[] | "\(.role | ascii_upcase)|\(.hostname)|\(.status)|\(.public_ip_address // "N/A")|\(.private_ip_address // "N/A")|\(.ssh_key_id // "")"' 2>/dev/null || true)
            
            if [[ -n "$node_servers" ]]; then
                if [[ -n "$servers" ]]; then
                    servers="$servers"$'\n'"$node_servers"
                else
                    servers="$node_servers"
                fi
            fi
            
            # Clear SSH keys when entering new cluster context
            clear_ssh_keys
            
            # Mode selection loop
            while true; do
                clear
                local mode
                local menu_options=()
                
                # Only add SSH/kubectl/kubeconfig options if bastion exists
                if [[ -n "$bastion_ip" ]] && [[ -n "$servers" ]]; then
                    menu_options+=("🚀 Quick connect (fresh kubeconfig + port-forward)" "🔗 SSH to servers" "📡 Port forward to master (6443)" "⚙️ Setup ~/.kube/config")
                fi
                
                # Add cluster action options (cluster exists in AutoGlue)
                menu_options+=("⚡ Cluster Actions")
                
                # Add clone option if there's a matched repo
                if [[ -n "$matched_repo" ]]; then
                    menu_options+=("📦 Clone Captain Repository ($matched_repo)")
                fi
                
                menu_options+=("◀ Back")
                
                # Format cluster status with appropriate emoji and color
                local status_display
                case "$cluster_status" in
                    ready)
                        status_display=$(gum style --foreground 82 "✓ $cluster_status")
                        ;;
                    provisioning|pending)
                        status_display=$(gum style --foreground 208 "⏳ $cluster_status")
                        ;;
                    failed)
                        status_display=$(gum style --foreground 196 "✗ $cluster_status")
                        ;;
                    *)
                        status_display="$cluster_status"
                        ;;
                esac
                
                mode=$(gum choose --header="Cluster: $cluster_selection ($status_display) - What would you like to do?" "${menu_options[@]}" || true)
                
                # Handle escape or empty selection
                if [[ -z "$mode" ]]; then
                    break
                fi
                
                case "$mode" in
                    "🚀 Quick connect (fresh kubeconfig + port-forward)")
                        quick_kubeconfig_mode "$cluster_id" "$bastion_ip" "$servers" "$org_id" "$bastion_key_id"
                        ;;
                    "🔗 SSH to servers")
                        ssh_mode "$cluster_id" "$bastion_ip" "$servers" "$org_id" "$bastion_key_id"
                        ;;
                    "📡 Port forward to master (6443)")
                        kubectl_mode "$cluster_id" "$bastion_ip" "$servers" "$org_id" "$bastion_key_id"
                        ;;
                    "⚙️ Setup ~/.kube/config")
                        kubeconfig_mode "$cluster_id" "$bastion_ip" "$servers" "$org_id" "$bastion_key_id"
                        ;;
                    "⚡ Cluster Actions")
                        cluster_actions_mode "$cluster_id" "$org_id"
                        ;;
                    📦*)
                        clone_repo_mode "$matched_repo" "$(get_gh_org)"
                        ;;
                    "◀ Back")
                        break
                        ;;
                esac
            done
        done
    done
}

# Clear all SSH keys from agent (called when entering a new cluster)
clear_ssh_keys() {
    # Check if ssh-agent is running (exit code 2 = not running, 0/1 = running)
    local agent_status=0
    ssh-add -l >/dev/null 2>&1 || agent_status=$?
    if [[ $agent_status -eq 2 ]]; then
        eval $(ssh-agent) > /dev/null
    fi
    
    # Clear all existing keys
    ssh-add -D >/dev/null 2>&1 || true
}

# Load a single SSH key to agent
load_ssh_key() {
    local org_id="$1"
    local key_id="$2"
    
    if [[ -z "$key_id" ]]; then
        return 0
    fi
    
    local key_data
    key_data=$(api_call GET "/ssh/$key_id?reveal=true" "$org_id" 2>/dev/null)
    local private_key
    private_key=$(echo "$key_data" | jq -r '.private_key' 2>/dev/null)
    
    # Add to ssh-agent
    echo "$private_key" | ssh-add - >/dev/null 2>&1
}

# Load SSH keys for a connection (loads bastion + target)
load_connection_keys() {
    local org_id="$1"
    local bastion_key_id="$2"
    local target_key_id="$3"
    
    # Check if ssh-agent is running (exit code 2 = not running, 0/1 = running)
    local agent_status=0
    ssh-add -l >/dev/null 2>&1 || agent_status=$?
    if [[ $agent_status -eq 2 ]]; then
        eval $(ssh-agent) > /dev/null
    fi
    
    # Load bastion key
    load_ssh_key "$org_id" "$bastion_key_id"
    
    # Load target key
    load_ssh_key "$org_id" "$target_key_id"
}

# SSH mode - show all servers, connect directly when selected
ssh_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    local org_id="$4"
    local bastion_key_id="$5"
    
    # Server selection loop
    while true; do
        clear
        # Build formatted server list
        local server_list=""
        while IFS='|' read -r role hostname status public_ip private_ip ssh_key_id; do
            local pub_display="${public_ip}"
            local priv_display="${private_ip}"
            [[ "$public_ip" == "N/A" ]] && pub_display="N/A"
            [[ "$private_ip" == "N/A" ]] && priv_display="N/A"
            server_list+="[${role}] ${hostname} - Public: ${pub_display}, Private: ${priv_display}"$'\n'
        done <<< "$servers"
        
        local server_selection
        server_selection=$(echo -e "${server_list}◀ Back" | gum choose --header="Select server to SSH into:" || true)
        
        # Handle ESC or Back
        if [[ -z "$server_selection" ]] || [[ "$server_selection" == "◀ Back" ]]; then
            return
        fi
        
        # Extract hostname (second word after [ROLE])
        local hostname
        hostname=$(echo "$server_selection" | awk '{print $2}')
        
        # Get the full server line to extract role, IPs, and ssh_key_id
        local server_line
        server_line=$(echo "$servers" | grep -F "|$hostname|")
        
        local role
        role=$(echo "$server_line" | cut -d'|' -f1)
        local private_ip
        private_ip=$(echo "$server_line" | cut -d'|' -f5)
        local public_ip
        public_ip=$(echo "$server_line" | cut -d'|' -f4)
        local target_key_id
        target_key_id=$(echo "$server_line" | cut -d'|' -f6)
        
        local target_ip
        if [[ -n "$private_ip" ]] && [[ "$private_ip" != "N/A" ]]; then
            target_ip="$private_ip"
        else
            target_ip="$public_ip"
        fi
        
        # Load SSH keys for this connection (clears old keys, loads bastion + target)
        load_connection_keys "$org_id" "$bastion_key_id" "$target_key_id"
        
        # Connect directly - after exit, returns to server list
        connect_ssh "$bastion_ip" "$cluster_id" "$hostname" "$role" "$target_ip" || true
    done
}

# kubectl mode - show only master nodes, port forward directly when selected
kubectl_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    local org_id="$4"
    local bastion_key_id="$5"
    
    local port_forward_pid=""
    local port_forward_master=""
    
    # Filter to only master nodes
    local master_servers
    master_servers=$(echo "$servers" | grep "^MASTER|" || true)
    
    if [[ -z "$master_servers" ]]; then
        echo "No master nodes found"
        return
    fi
    
    # Master selection loop
    while true; do
        clear
        
        # Check if port forward is still running
        if [[ -n "$port_forward_pid" ]] && ! kill -0 "$port_forward_pid" 2>/dev/null; then
            port_forward_pid=""
            port_forward_master=""
        fi
        
        # Show status
        if [[ -n "$port_forward_pid" ]]; then
            gum style --foreground 82 "✓ Port forward active: localhost:6443 -> $port_forward_master:6443 (PID: $port_forward_pid)"
            echo ""
        fi
        
        # Format master list for display
        local server_list
        server_list=$(echo "$master_servers" | awk -F'|' '{printf "[%s] %s (%s)\n", $1, $2, $3}')
        
        # Build menu options
        local menu_items
        if [[ -n "$port_forward_pid" ]]; then
            menu_items=$(echo -e "$server_list\n🛑 Stop Port Forward\n◀ Back")
        else
            menu_items=$(echo -e "$server_list\n◀ Back")
        fi
        
        local server_selection
        server_selection=$(echo "$menu_items" | gum choose --header="Select master node for kubectl port forward:" || true)
        
        # Handle ESC or Back
        if [[ -z "$server_selection" ]] || [[ "$server_selection" == "◀ Back" ]]; then
            # Clean up port forward if running
            if [[ -n "$port_forward_pid" ]]; then
                kill "$port_forward_pid" 2>/dev/null || true
            fi
            return
        fi
        
        # Handle stop port forward
        if [[ "$server_selection" == "🛑 Stop Port Forward" ]]; then
            if [[ -n "$port_forward_pid" ]]; then
                kill "$port_forward_pid" 2>/dev/null || true
                port_forward_pid=""
                port_forward_master=""
                gum style --foreground 82 "✓ Port forward stopped"
                sleep 1
            fi
            continue
        fi
        
        # Extract hostname
        local hostname
        hostname=$(echo "$server_selection" | sed -n 's/.*] \([^ ]*\).*/\1/p')
        
        # Get the IP for this server - prefer private, fallback to public
        local server_line
        server_line=$(echo "$master_servers" | grep -F "|$hostname|" || true)
        local private_ip
        private_ip=$(echo "$server_line" | cut -d'|' -f5)
        local public_ip
        public_ip=$(echo "$server_line" | cut -d'|' -f4)
        local target_key_id
        target_key_id=$(echo "$server_line" | cut -d'|' -f6)
        
        local target_ip
        if [[ -n "$private_ip" ]] && [[ "$private_ip" != "N/A" ]]; then
            target_ip="$private_ip"
        else
            target_ip="$public_ip"
        fi
        
        # Load SSH keys for this connection (clears old keys, loads bastion + target)
        load_connection_keys "$org_id" "$bastion_key_id" "$target_key_id"
        
        # Stop existing port forward if running
        if [[ -n "$port_forward_pid" ]]; then
            kill "$port_forward_pid" 2>/dev/null || true
            port_forward_pid=""
            port_forward_master=""
        fi
        
        # Check if port 6443 is already in use
        if lsof -ti :6443 >/dev/null 2>&1; then
            gum style --foreground 196 "✗ Port 6443 is already in use"
            echo ""
            echo "Kill the existing process? (This will stop any existing port forward)"
            if gum confirm "Kill process on port 6443?"; then
                lsof -ti :6443 | xargs kill -9 2>/dev/null || true
                sleep 2
                
                # Verify port is now free
                if lsof -ti :6443 >/dev/null 2>&1; then
                    gum style --foreground 196 "✗ Failed to kill process on port 6443"
                    echo ""
                    read -n 1 -s -r -p "Press any key to continue..." || true
                    continue
                fi
            else
                continue
            fi
        fi
        
        # Tunnel to the master via the bastion; binds 6443 locally only.
        echo "Starting port forward: localhost:6443 -> $hostname:6443 (via bastion)"

        # Create a temporary error log
        local error_log=$(mktemp)

        # Start port forward with error output captured - using proper backgrounding
        (ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes \
            -o ProxyCommand="$(bastion_proxy "$bastion_ip")" \
            -N -L 6443:localhost:6443 cluster@"$target_ip" \
            2>"$error_log") &
        
        local ssh_pid=$!
        port_forward_master="$hostname"
        
        # Wait and check if it started successfully
        sleep 3
        
        # Find the actual port forward process (not the parent shell)
        local actual_pid=$(lsof -ti :6443 2>/dev/null || echo "")
        
        if [[ -n "$actual_pid" ]] && kill -0 "$ssh_pid" 2>/dev/null; then
            port_forward_pid="$ssh_pid"
            gum style --foreground 82 "✓ Port forward started successfully (PID: $ssh_pid)"
            rm -f "$error_log"
        else
            gum style --foreground 196 "✗ Port forward failed to start"
            
            # Try to read error log
            if [[ -s "$error_log" ]]; then
                echo ""
                echo "Error details:"
                cat "$error_log"
            else
                echo ""
                echo "No error details available. Possible reasons:"
                echo "  - SSH keys not loaded (try SSH to a server first)"
                echo "  - Master node not accessible"
                echo "  - Network connectivity issue"
            fi
            
            rm -f "$error_log"
            
            # Clean up the failed SSH process
            kill "$ssh_pid" 2>/dev/null || true
            
            port_forward_pid=""
            port_forward_master=""
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
        fi
        sleep 1
    done
}

# kubeconfig mode - copy admin.conf from master to ~/.kube/config
kubeconfig_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    local org_id="$4"
    local bastion_key_id="$5"
    
    # Filter to only master nodes
    local master_servers
    master_servers=$(echo "$servers" | grep "^MASTER|" || true)
    
    if [[ -z "$master_servers" ]]; then
        echo "No master nodes found"
        return
    fi
    
    # Format for display
    local server_list
    server_list=$(echo "$master_servers" | awk -F'|' '{printf "[%s] %s (%s)\n", $1, $2, $3}')
    
    local server_selection
    server_selection=$(echo -e "$server_list\n◀ Back" | gum choose --header="Select master node to get kubeconfig from:" || true)
    
    # Handle escape or empty selection
    if [[ -z "$server_selection" ]] || [[ "$server_selection" == "◀ Back" ]]; then
        return
    fi
    
    # Extract hostname
    local hostname
    hostname=$(echo "$server_selection" | sed -n 's/.*] \([^ ]*\).*/\1/p')
    
    # Get the IP for this server - prefer private, fallback to public
    local server_line
    server_line=$(echo "$master_servers" | grep -F "|$hostname|" || true)
    local private_ip
    private_ip=$(echo "$server_line" | cut -d'|' -f5)
    local public_ip
    public_ip=$(echo "$server_line" | cut -d'|' -f4)
    local target_key_id
    target_key_id=$(echo "$server_line" | cut -d'|' -f6)
    
    local target_ip
    if [[ -n "$private_ip" ]] && [[ "$private_ip" != "N/A" ]]; then
        target_ip="$private_ip"
    else
        target_ip="$public_ip"
    fi
    
    # Create ~/.kube directory if it doesn't exist
    mkdir -p ~/.kube
    
    # Load SSH keys for this connection (clears old keys, loads bastion + target)
    load_connection_keys "$org_id" "$bastion_key_id" "$target_key_id"
    
    echo "Fetching kubeconfig from $hostname..."
    
    if ssh "${SSH_OPTS[@]}" -o ProxyCommand="$(bastion_proxy "$bastion_ip")" cluster@"$target_ip" \
        'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/config 2>/dev/null; then
        # Update the server URL to localhost:6443
        if kubectl config set-cluster "kubernetes" --server=https://127.0.0.1:6443 >/dev/null 2>&1; then
            echo "✓ Kubeconfig saved to ~/.kube/config"
            echo "✓ Server URL updated to https://127.0.0.1:6443"
        else
            echo "✓ Kubeconfig saved to ~/.kube/config"
            echo "⚠️  Could not update server URL (kubectl not found?)"
        fi
    else
        echo "✗ Failed to fetch kubeconfig"
    fi
    
    echo ""
    read -n 1 -s -r -p "Press any key to continue..." || true
    echo ""
}

# True if ANY local TCP socket is using port 6443 (LISTEN, ESTABLISHED, or
# TIME_WAIT). lsof alone misses sockets it can't attribute (e.g. root-owned)
# and TIME_WAIT leftovers, so fall back to `ss -tan`, which sees them all.
port6443_in_use() {
    lsof -ti :6443 >/dev/null 2>&1 && return 0
    if command -v ss >/dev/null 2>&1; then
        ss -tan 2>/dev/null | awk 'NR>1 { n=split($4,a,":"); if (a[n]=="6443") { found=1; exit } } END { exit found?0:1 }' && return 0
    fi
    return 1
}

# Print the PIDs currently holding local port 6443 (best effort; TIME_WAIT
# sockets have no owning process and won't appear).
port6443_pids() {
    {
        lsof -ti :6443 2>/dev/null || true
        if command -v ss >/dev/null 2>&1; then
            ss -tlnp 2>/dev/null | awk 'NR>1 { n=split($4,a,":"); if (a[n]=="6443") print }' \
                | grep -oE 'pid=[0-9]+' | cut -d= -f2 || true
        fi
    } | sort -u
}

# Core quick-connect action (shared by the interactive menu and the headless
# --cluster path): load keys, free port 6443, nuke ~/.kube/config, fetch a
# fresh one from the given master, then foreground port-forward to it.
# Blocks until the user hits Ctrl+C. Returns non-zero on setup failure.
kubeconfig_and_port_forward() {
    local bastion_ip="$1"
    local hostname="$2"
    local target_ip="$3"
    local org_id="$4"
    local bastion_key_id="$5"
    local target_key_id="$6"

    # Load SSH keys for this connection (clears old keys, loads bastion + target)
    load_connection_keys "$org_id" "$bastion_key_id" "$target_key_id"

    # Free local port 6443. The fetched kubeconfig pins the API server to
    # 127.0.0.1:6443, so the forward MUST use exactly this port - we can't just
    # pick another one. Kill any process holding it (escalate to sudo for
    # root-owned listeners); a TIME_WAIT leftover has no owner and can't be
    # killed, so surface that clearly instead of failing cryptically later.
    if port6443_in_use; then
        gum style --foreground 208 "⚠️  Port 6443 in use - freeing it..."
        local held_pids
        held_pids=$(port6443_pids)
        if [[ -n "$held_pids" ]]; then
            # Show what we're about to kill so it isn't a silent SIGKILL
            while read -r _p; do
                [[ -z "$_p" ]] && continue
                echo "  killing PID $_p ($(ps -o comm= -p "$_p" 2>/dev/null || echo '?'))"
            done <<< "$held_pids"
            echo "$held_pids" | xargs -r kill -9 2>/dev/null || true
            if port6443_in_use && command -v sudo >/dev/null 2>&1; then
                echo "$held_pids" | xargs -r sudo -n kill -9 2>/dev/null || true
            fi
        fi
        sleep 2
        if port6443_in_use; then
            gum style --foreground 196 "✗ Could not free port 6443. Still held by:"
            ss -tanp 2>/dev/null | awk 'NR==1 || $4 ~ /:6443$/' || true
            echo ""
            echo "If nothing owns it above, it is likely a socket in TIME_WAIT -"
            echo "wait ~30s and re-run, or stop whatever is using localhost:6443."
            return 1
        fi
    fi

    # Fetch a fresh kubeconfig into a temp file first, and only replace
    # ~/.kube/config once we know it succeeded. A failed refresh (bastion
    # unreachable, key not loaded, sudo denied) then leaves the user's existing
    # kubeconfig intact instead of nuking it and leaving them with nothing.
    mkdir -p ~/.kube
    local kube_tmp
    kube_tmp=$(mktemp)
    echo "Fetching fresh kubeconfig from $hostname..."

    if ssh "${SSH_OPTS[@]}" -o ProxyCommand="$(bastion_proxy "$bastion_ip")" cluster@"$target_ip" \
        'sudo cat /etc/kubernetes/admin.conf' > "$kube_tmp" 2>/dev/null && [[ -s "$kube_tmp" ]]; then
        mv "$kube_tmp" ~/.kube/config
        # Point the kubeconfig at the local port-forward
        if kubectl config set-cluster "kubernetes" --server=https://127.0.0.1:6443 >/dev/null 2>&1; then
            gum style --foreground 82 "✓ Fresh kubeconfig saved (server → https://127.0.0.1:6443)"
        else
            gum style --foreground 82 "✓ Fresh kubeconfig saved to ~/.kube/config"
            gum style --foreground 208 "⚠️  Could not update server URL (kubectl not found?)"
        fi
    else
        rm -f "$kube_tmp"
        gum style --foreground 196 "✗ Failed to fetch kubeconfig - aborting (existing ~/.kube/config left untouched)"
        return 1
    fi

    # Foreground port-forward to the master via the bastion; binds 6443 locally only.
    echo ""
    echo "Starting port forward: localhost:6443 -> $hostname:6443 (via bastion)"
    echo "Leave this running; use kubectl from another terminal (e.g. kubectl get nodes)."
    echo "Press Ctrl+C to stop."
    echo ""

    # Distinguish a fast bind failure from a normal user Ctrl+C via exit code + elapsed time.
    local fwd_start fwd_rc=0
    fwd_start=$(date +%s)
    ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes \
        -o ProxyCommand="$(bastion_proxy "$bastion_ip")" \
        -N -L 6443:localhost:6443 cluster@"$target_ip" || fwd_rc=$?
    local fwd_elapsed=$(( $(date +%s) - fwd_start ))

    echo ""
    # ssh exits 130 (SIGINT) / 143 (SIGTERM) on a clean Ctrl+C - never a failure,
    # even if the user cancels within the first few seconds. Only a quick,
    # non-signal, non-zero exit means the tunnel could not be set up.
    if [[ $fwd_rc -ne 0 && $fwd_rc -ne 130 && $fwd_rc -ne 143 && $fwd_elapsed -lt 4 ]]; then
        gum style --foreground 196 "✗ Port forward failed to start (ssh exit $fwd_rc after ${fwd_elapsed}s)."
        echo "Could not establish the tunnel. If local port 6443 is in use:"
        ss -tanp 2>/dev/null | awk 'NR==1 || $4 ~ /:6443$/' || true
        echo ""
        echo "Otherwise a previous tunnel may be lingering on the bastion; re-run to retry."
        return 1
    fi

    echo "Port forward closed."
    return 0
}

# Quick mode - nuke kubeconfig, fetch a fresh one from a master, then
# port-forward localhost:6443 to that SAME master (interactive menu entry).
quick_kubeconfig_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    local org_id="$4"
    local bastion_key_id="$5"

    # Filter to only master nodes
    local master_servers
    master_servers=$(echo "$servers" | grep "^MASTER|" || true)

    if [[ -z "$master_servers" ]]; then
        echo "No master nodes found"
        echo ""
        read -n 1 -s -r -p "Press any key to continue..." || true
        return
    fi

    # Select a master - auto-pick when there is only one (faster)
    local hostname
    local master_count
    master_count=$(echo "$master_servers" | grep -c "^MASTER|")

    if [[ "$master_count" -eq 1 ]]; then
        hostname=$(echo "$master_servers" | head -n1 | cut -d'|' -f2)
    else
        clear
        local server_list
        server_list=$(echo "$master_servers" | awk -F'|' '{printf "[%s] %s (%s)\n", $1, $2, $3}')

        local server_selection
        server_selection=$(echo -e "$server_list\n◀ Back" | gum choose --header="Select master (fresh kubeconfig + port-forward):" || true)

        # Handle escape or empty selection
        if [[ -z "$server_selection" ]] || [[ "$server_selection" == "◀ Back" ]]; then
            return
        fi

        hostname=$(echo "$server_selection" | sed -n 's/.*] \([^ ]*\).*/\1/p')
    fi

    # Resolve the target IP (prefer private, fallback to public) and SSH key
    local server_line
    server_line=$(echo "$master_servers" | grep -F "|$hostname|" || true)
    local private_ip
    private_ip=$(echo "$server_line" | cut -d'|' -f5)
    local public_ip
    public_ip=$(echo "$server_line" | cut -d'|' -f4)
    local target_key_id
    target_key_id=$(echo "$server_line" | cut -d'|' -f6)

    local target_ip
    if [[ -n "$private_ip" ]] && [[ "$private_ip" != "N/A" ]]; then
        target_ip="$private_ip"
    else
        target_ip="$public_ip"
    fi

    clear
    gum style --border rounded --padding "1 2" "Quick connect: $hostname"
    echo ""

    kubeconfig_and_port_forward "$bastion_ip" "$hostname" "$target_ip" "$org_id" "$bastion_key_id" "$target_key_id" || true

    echo ""
    read -n 1 -s -r -p "Press any key to continue..." || true
    echo ""
}

# Helper function to format ISO8601 timestamp to readable format
format_timestamp() {
    local timestamp="$1"
    
    if [[ -z "$timestamp" ]] || [[ "$timestamp" == "N/A" ]] || [[ "$timestamp" == "null" ]]; then
        echo "N/A"
        return
    fi
    
    # Convert ISO8601 to readable format: "2026-01-11 09:44 UTC"
    date -u -d "$timestamp" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$timestamp"
}

# Helper function to calculate relative time
relative_time() {
    local timestamp="$1"
    
    if [[ -z "$timestamp" ]] || [[ "$timestamp" == "N/A" ]] || [[ "$timestamp" == "null" ]]; then
        echo "N/A"
        return
    fi
    
    local now=$(date +%s)
    local then=$(date -d "$timestamp" +%s 2>/dev/null || echo "0")
    
    if [[ "$then" == "0" ]]; then
        echo "unknown"
        return
    fi
    
    local diff=$((now - then))
    
    if [[ $diff -lt 0 ]]; then
        diff=$((diff * -1))
    fi
    
    if [[ $diff -lt 60 ]]; then
        echo "${diff}s ago"
    elif [[ $diff -lt 3600 ]]; then
        local minutes=$((diff / 60))
        echo "${minutes}m ago"
    elif [[ $diff -lt 86400 ]]; then
        local hours=$((diff / 3600))
        echo "${hours}h ago"
    else
        local days=$((diff / 86400))
        echo "${days}d ago"
    fi
}

# Cluster actions mode - submenu for trigger and view
cluster_actions_mode() {
    local cluster_id="$1"
    local org_id="$2"
    
    while true; do
        clear
        local action_choice
        action_choice=$(gum choose --header="Cluster Actions - What would you like to do?" \
            "🚀 Trigger" \
            "📊 View" \
            "◀ Back" || true)
        
        case "$action_choice" in
            "🚀 Trigger")
                run_actions_mode "$cluster_id" "$org_id"
                ;;
            "📊 View")
                view_runs_mode "$cluster_id" "$org_id"
                ;;
            "◀ Back"|"")
                return
                ;;
        esac
    done
}

# Run actions mode - list available actions and trigger cluster runs
run_actions_mode() {
    local cluster_id="$1"
    local org_id="$2"
    
    # Action selection loop
    while true; do
        clear
        echo "Fetching available actions..."
        
        # Fetch actions from API
        local actions
        actions=$(api_call GET "/admin/actions" "$org_id" 2>/dev/null)
        
        # Check if actions were fetched successfully
        if [[ -z "$actions" ]] || [[ "$actions" == "null" ]]; then
            gum style --foreground 196 "✗ Failed to fetch actions or no actions available"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
            return
        fi
        
        # Check if actions array is empty
        local action_count
        action_count=$(echo "$actions" | jq 'length' 2>/dev/null)
        if [[ "$action_count" == "0" ]]; then
            gum style --foreground 208 "No actions available"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
            return
        fi
        
        # Build action list with format: [label] description|action_id
        local action_list
        action_list=$(echo "$actions" | jq -r '.[] | "[\(.label)] \(.description // "No description")|\(.id)"')
        
        if [[ -z "$action_list" ]]; then
            gum style --foreground 196 "✗ No actions found"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
            return
        fi
        
        # Show action selection menu
        local action_display
        action_display=$(echo "$action_list" | cut -d'|' -f1)
        
        local action_selection
        action_selection=$(echo -e "$action_display\n◀ Back" | gum choose --header="Select action to run:" || true)
        
        # Handle ESC or Back
        if [[ -z "$action_selection" ]] || [[ "$action_selection" == "◀ Back" ]]; then
            return
        fi
        
        # Extract action ID
        local action_id
        action_id=$(echo "$action_list" | grep -F "$action_selection" | cut -d'|' -f2)
        
        # Confirm action execution
        if ! gum confirm "Run action: $action_selection?"; then
            continue
        fi
        
        echo ""
        echo "Triggering cluster run..."
        
        # Trigger cluster run
        local run_response
        run_response=$(curl -s -X POST \
            -H "X-API-KEY: $API_KEY" \
            -H "X-Org-ID: $org_id" \
            "$API_ENDPOINT/clusters/$cluster_id/actions/$action_id/runs" 2>/dev/null)
        
        # Check if run was created successfully
        local run_id
        run_id=$(echo "$run_response" | jq -r '.id // empty' 2>/dev/null)
        
        if [[ -n "$run_id" ]]; then
            local run_status
            run_status=$(echo "$run_response" | jq -r '.status // "unknown"')
            gum style --foreground 82 "✓ Cluster run created successfully"
            echo "Run ID: $run_id"
            echo "Status: $run_status"
        else
            local error_msg
            error_msg=$(echo "$run_response" | jq -r '.message // "Unknown error"' 2>/dev/null)
            gum style --foreground 196 "✗ Failed to create cluster run"
            echo "Error: $error_msg"
        fi
        
        echo ""
        read -n 1 -s -r -p "Press any key to continue..." || true
        echo ""
    done
}

# View runs mode - show cluster runs with status tracking
view_runs_mode() {
    local cluster_id="$1"
    local org_id="$2"
    
    # Run selection loop
    while true; do
        clear
        echo "Fetching cluster runs..."
        
        # Fetch cluster runs
        local runs
        runs=$(api_call GET "/clusters/$cluster_id/runs" "$org_id" 2>/dev/null)
        
        # Check if runs were fetched successfully
        if [[ -z "$runs" ]] || [[ "$runs" == "null" ]]; then
            gum style --foreground 196 "✗ Failed to fetch cluster runs"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
            return
        fi
        
        # Check if runs array is empty
        local run_count
        run_count=$(echo "$runs" | jq 'length' 2>/dev/null)
        if [[ "$run_count" == "0" ]]; then
            gum style --foreground 208 "No cluster runs found"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
            return
        fi
        
        # Build run list with color-coded status
        local run_list=""
        while IFS='|' read -r run_id action status created_at; do
            local status_icon
            case "$status" in
                succeeded)
                    status_icon="✓"
                    ;;
                running|queued)
                    status_icon="⏳"
                    ;;
                failed)
                    status_icon="✗"
                    ;;
                *)
                    status_icon="•"
                    ;;
            esac
            local formatted_time=$(format_timestamp "$created_at")
            local relative=$(relative_time "$created_at")
            run_list+="[$status_icon $status] $action - $formatted_time ($relative)|$run_id"$'\n'
        done < <(echo "$runs" | jq -r '.[] | "\(.id)|\(.action)|\(.status)|\(.created_at)"' | awk -F'|' '{print $1 "|" $2 "|" $3 "|" $4}')
        
        # Add Refresh option
        local run_display
        run_display=$(echo "$run_list" | cut -d'|' -f1)
        
        local run_selection
        run_selection=$(echo -e "$run_display\n🔄 Refresh\n◀ Back" | gum choose --header="Select run to view details:" || true)
        
        # Handle ESC or Back
        if [[ -z "$run_selection" ]] || [[ "$run_selection" == "◀ Back" ]]; then
            return
        fi
        
        # Handle Refresh
        if [[ "$run_selection" == "🔄 Refresh" ]]; then
            continue
        fi
        
        # Extract run ID
        local selected_run_id
        selected_run_id=$(echo "$run_list" | grep -F "$run_selection" | cut -d'|' -f2)
        
        # Detail view loop with auto-refresh for active runs
        while true; do
            # Fetch detailed run info
            clear
            echo "Fetching run details..."
            
            local run_detail
            run_detail=$(api_call GET "/clusters/$cluster_id/runs/$selected_run_id" "$org_id" 2>/dev/null)
            
            if [[ -n "$run_detail" ]] && [[ "$run_detail" != "null" ]]; then
                clear
                gum style --border rounded --padding "1 2" "Cluster Run Details"
                echo ""
                
                local detail_id detail_action detail_status detail_error detail_created detail_updated detail_finished
                detail_id=$(echo "$run_detail" | jq -r '.id // "N/A"')
                detail_action=$(echo "$run_detail" | jq -r '.action // "N/A"')
                detail_status=$(echo "$run_detail" | jq -r '.status // "N/A"')
                detail_error=$(echo "$run_detail" | jq -r '.error // "None"')
                detail_created=$(echo "$run_detail" | jq -r '.created_at // "N/A"')
                detail_updated=$(echo "$run_detail" | jq -r '.updated_at // "N/A"')
                detail_finished=$(echo "$run_detail" | jq -r '.finished_at // "N/A"')
                
                # Format timestamps
                local formatted_created=$(format_timestamp "$detail_created")
                local relative_created=$(relative_time "$detail_created")
                local formatted_updated=$(format_timestamp "$detail_updated")
                local relative_updated=$(relative_time "$detail_updated")
                local formatted_finished=$(format_timestamp "$detail_finished")
                local relative_finished=$(relative_time "$detail_finished")
                
                echo "ID: $detail_id"
                echo "Action: $detail_action"
                
                # Color-code status
                case "$detail_status" in
                    succeeded)
                        echo -n "Status: "
                        gum style --foreground 82 "✓ $detail_status"
                        ;;
                    running|queued)
                        echo -n "Status: "
                        gum style --foreground 208 "⏳ $detail_status"
                        ;;
                    failed)
                        echo -n "Status: "
                        gum style --foreground 196 "✗ $detail_status"
                        ;;
                    *)
                        echo "Status: $detail_status"
                        ;;
                esac
                
                echo "Created: $formatted_created ($relative_created)"
                echo "Updated: $formatted_updated ($relative_updated)"
                echo "Finished: $formatted_finished ($relative_finished)"
                
                if [[ -n "$detail_error" ]] && [[ "$detail_error" != "None" ]] && [[ "$detail_error" != "null" ]]; then
                    echo ""
                    gum style --foreground 196 "Error:"
                    echo "$detail_error"
                fi
                
                # Auto-refresh for active runs
                if [[ "$detail_status" == "running" ]] || [[ "$detail_status" == "queued" ]]; then
                    echo ""
                    echo "(Auto-refreshing in 3s... Press any key to return to list)"
                    if read -t 3 -n 1 -s -r 2>/dev/null; then
                        break
                    fi
                    # Continue loop to refresh
                else
                    # Run completed, wait for user input
                    echo ""
                    read -n 1 -s -r -p "Press any key to continue..." || true
                    echo ""
                    break
                fi
            else
                gum style --foreground 196 "✗ Failed to fetch run details"
                echo ""
                read -n 1 -s -r -p "Press any key to continue..." || true
                echo ""
                break
            fi
        done
    done
}

# Clone Captain Repository mode
clone_repo_mode() {
    local repo_name="$1"
    local org="$2"
    
    if [[ -z "$repo_name" ]]; then
        return
    fi
    
    local repo_exists=false
    local clone_success=false
    
    # Check if directory already exists
    if [[ -d "$repo_name" ]]; then
        repo_exists=true
        if [[ -d "$repo_name/.git" ]]; then
            echo "Checking repository status..."
            
            # Fetch latest from origin
            (cd "$repo_name" && git fetch origin 2>&1 | grep -v "^From" || true)
            
            # Get status
            local status
            status=$(cd "$repo_name" && git status --porcelain --branch)
            
            # Check for various conditions
            local has_uncommitted=false
            local has_unpushed=false
            local has_unpulled=false
            
            # Check for uncommitted changes (any line not starting with ##)
            if echo "$status" | grep -q "^[^#]"; then
                has_uncommitted=true
            fi
            
            # Check branch status line for ahead/behind
            local branch_line
            branch_line=$(echo "$status" | grep "^##" || true)
            
            if echo "$branch_line" | grep -q "\[ahead [0-9]\+\]"; then
                has_unpushed=true
            fi
            
            if echo "$branch_line" | grep -q "\[behind [0-9]\+\]"; then
                has_unpulled=true
            fi
            
            # Display warnings or success
            if [[ "$has_uncommitted" == "true" ]] || [[ "$has_unpushed" == "true" ]] || [[ "$has_unpulled" == "true" ]]; then
                echo ""
                [[ "$has_uncommitted" == "true" ]] && echo "⚠️  Repository has uncommitted changes"
                [[ "$has_unpushed" == "true" ]] && echo "⚠️  Repository has unpushed commits"
                [[ "$has_unpulled" == "true" ]] && echo "⚠️  Repository has unpulled commits from origin"
                echo ""
            else
                echo "✓ Repository is up to date"
            fi
            
            clone_success=true
        else
            echo "Directory '$repo_name' already exists (not a git repository)"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
            return
        fi
    else
        # Clone the repository
        if gh repo clone "$org/$repo_name" "$repo_name" 2>&1; then
            clone_success=true
            echo ""
            gum style --foreground 82 "✓ Repository cloned successfully"
        else
            echo ""
            gum style --foreground 196 "✗ Failed to clone repository"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
            return
        fi
    fi
    
    # Offer to open a shell in the repository directory
    if [[ "$clone_success" == "true" ]]; then
        echo ""
        local shell_choice
        shell_choice=$(gum choose --header="What would you like to do?" \
            "🐚 Open shell in repository" \
            "◀ Back" || true)
        
        if [[ "$shell_choice" == "🐚 Open shell in repository" ]]; then
            echo ""
            echo "Opening shell in $repo_name/ (type 'exit' to return)"
            echo ""
            (cd "$repo_name" && exec $SHELL)
        fi
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
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR cluster@"$bastion_ip"
    else
        
        ssh "${SSH_OPTS[@]}" -o ProxyCommand="$(bastion_proxy "$bastion_ip")" -t cluster@"$target_ip"
    fi
}

usage() {
    cat <<'EOF'
gluekube_ssh - AutoGlue SSH / kubeconfig helper

USAGE:
  gluekube_ssh                                   Interactive mode (profile → org → cluster menu)
  gluekube_ssh --profile <name>                  Interactive, starting from a saved profile
  gluekube_ssh --profile <name> --cluster <fqdn> --kubectl [--org <name>]
                                                 Headless quick-connect: nuke ~/.kube/config,
                                                 fetch a fresh one from the first master, and
                                                 foreground port-forward localhost:6443 to it.

OPTIONS:
  --profile <name>   Saved profile to use (required for --cluster / --kubectl)
  --cluster <fqdn>   Which cluster to target
  --kubectl          Action: quick-connect (fresh kubeconfig + port-forward to the first
                     master). Requires --cluster.
  --org <name>       Limit cluster lookup to this org (optional; otherwise all orgs are scanned)
  -h, --help         Show this help

EXAMPLE:
  gluekube_ssh --profile nonprod --cluster nonprod.foobar.onglueops.com --kubectl
EOF
}

# Headless quick-connect: resolve a cluster by name (scanning orgs, or the one
# given via --org), pick its FIRST master, and run the shared quick-connect.
headless_quick_connect() {
    local cluster_name="$1"
    local org_filter="${2:-}"

    echo "Resolving cluster '$cluster_name'..."

    local orgs
    orgs=$(api_call GET "/orgs")

    # Build "id|name" org entries, optionally narrowed to --org
    local org_entries
    org_entries=$(echo "$orgs" | jq -r '.[] | "\(.id)|\(.name)"' 2>/dev/null || true)

    if [[ -z "$org_entries" ]]; then
        gum style --foreground 196 "✗ No organizations found (check API key / endpoint)"
        return 1
    fi

    if [[ -n "$org_filter" ]]; then
        # Explicit --org: query only that org
        org_entries=$(echo "$org_entries" | awk -F'|' -v o="$org_filter" '$2==o')
        if [[ -z "$org_entries" ]]; then
            gum style --foreground 196 "✗ Org '$org_filter' not found"
            return 1
        fi
    else
        # Fast path: the cluster FQDN encodes its org - e.g. cluster
        # "nonprod.foobar.onglueops.com" lives in org "foobar.onglueops.com"
        # (the cluster name minus its first DNS label). Try that org FIRST so
        # the common case is a single /clusters call; the loop below still
        # falls through to the remaining orgs if the convention doesn't hold.
        local guess_org="${cluster_name#*.}"
        if [[ -n "$guess_org" && "$guess_org" != "$cluster_name" ]]; then
            org_entries=$(echo "$org_entries" | awk -F'|' -v o="$guess_org" \
                '$2==o{print} $2!=o{buf[n++]=$0} END{for(i=0;i<n;i++) print buf[i]}')
        fi
    fi

    # Scan org(s) for a cluster whose name matches; first match wins (the
    # derived org, if any, is tried first)
    local found_org_id="" found_cluster_id="" all_names=""
    local org_id org_name clusters match names
    while IFS='|' read -r org_id org_name; do
        [[ -z "$org_id" ]] && continue
        clusters=$(api_call GET "/clusters" "$org_id")
        names=$(echo "$clusters" | jq -r '.[].name' 2>/dev/null || true)
        [[ -n "$names" ]] && all_names+="$names"$'\n'
        match=$(echo "$clusters" | jq -r --arg n "$cluster_name" '.[] | select(.name==$n) | .id' 2>/dev/null | head -n1 || true)
        if [[ -n "$match" ]]; then
            found_org_id="$org_id"
            found_cluster_id="$match"
            break
        fi
    done <<< "$org_entries"

    if [[ -z "$found_cluster_id" ]]; then
        gum style --foreground 196 "✗ Cluster '$cluster_name' not found"
        echo ""
        echo "Available clusters:"
        echo "$all_names" | sed '/^$/d' | sort -u | sed 's/^/  - /'
        return 1
    fi

    # Fetch full cluster details
    local cluster
    cluster=$(api_call GET "/clusters/$found_cluster_id" "$found_org_id")

    local bastion_ip bastion_key_id
    bastion_ip=$(echo "$cluster" | jq -r '.bastion_server.public_ip_address // empty')
    bastion_key_id=$(echo "$cluster" | jq -r '.bastion_server.ssh_key_id // empty')

    if [[ -z "$bastion_ip" ]]; then
        gum style --foreground 196 "✗ Cluster '$cluster_name' has no bastion - cannot connect"
        return 1
    fi

    # First master node
    local master_line
    master_line=$(echo "$cluster" | jq -r '.node_pools[].servers[] | select((.role|ascii_downcase)=="master") | "\(.role|ascii_upcase)|\(.hostname)|\(.status)|\(.public_ip_address // "N/A")|\(.private_ip_address // "N/A")|\(.ssh_key_id // "")"' 2>/dev/null | head -n1 || true)

    if [[ -z "$master_line" ]]; then
        gum style --foreground 196 "✗ No master nodes found for cluster '$cluster_name'"
        return 1
    fi

    local hostname public_ip private_ip target_key_id
    hostname=$(echo "$master_line" | cut -d'|' -f2)
    public_ip=$(echo "$master_line" | cut -d'|' -f4)
    private_ip=$(echo "$master_line" | cut -d'|' -f5)
    target_key_id=$(echo "$master_line" | cut -d'|' -f6)

    local target_ip
    if [[ -n "$private_ip" ]] && [[ "$private_ip" != "N/A" ]]; then
        target_ip="$private_ip"
    else
        target_ip="$public_ip"
    fi

    gum style --border rounded --padding "1 2" "Quick connect: $cluster_name → $hostname"
    echo ""

    kubeconfig_and_port_forward "$bastion_ip" "$hostname" "$target_ip" "$found_org_id" "$bastion_key_id" "$target_key_id"
}

# Main
main() {
    local arg_profile="" arg_cluster="" arg_org="" arg_kubectl=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                arg_profile="${2:-}"
                [[ -z "$arg_profile" || "$arg_profile" == -* ]] && { echo "Error: --profile requires a value" >&2; exit 1; }
                shift 2
                ;;
            --cluster)
                arg_cluster="${2:-}"
                [[ -z "$arg_cluster" || "$arg_cluster" == -* ]] && { echo "Error: --cluster requires a value" >&2; exit 1; }
                shift 2
                ;;
            --kubectl)
                arg_kubectl=true
                shift
                ;;
            --org)
                arg_org="${2:-}"
                [[ -z "$arg_org" || "$arg_org" == -* ]] && { echo "Error: --org requires a value" >&2; exit 1; }
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Error: unknown argument '$1'" >&2
                echo "" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    # Resolve profile (headless --cluster / --kubectl require one)
    if [[ -n "$arg_profile" ]]; then
        SELECTED_PROFILE="$arg_profile"
        local profile
        profile=$(get_profile "$arg_profile")

        if [[ -z "$profile" ]]; then
            gum style --foreground 196 "Profile '$arg_profile' not found"
            exit 1
        fi

        API_KEY=$(echo "$profile" | jq -r '.api_key')
        API_ENDPOINT=$(echo "$profile" | jq -r '.api_endpoint')
    elif [[ -n "$arg_cluster" ]] || [[ "$arg_kubectl" == true ]]; then
        echo "Error: --cluster / --kubectl require --profile" >&2
        exit 1
    else
        # Interactive profile selection
        profile_menu
    fi

    # Headless quick-connect: --kubectl is the action, --cluster names the target
    if [[ "$arg_kubectl" == true ]]; then
        if [[ -z "$arg_cluster" ]]; then
            echo "Error: --kubectl requires --cluster <fqdn>" >&2
            exit 1
        fi
        local rc=0
        headless_quick_connect "$arg_cluster" "$arg_org" || rc=$?
        exit "$rc"
    elif [[ -n "$arg_cluster" ]]; then
        echo "Error: --cluster requires an action (add --kubectl)" >&2
        exit 1
    fi

    # Otherwise, browse infrastructure - loops internally until the user exits
    browse_infrastructure
}

main "$@"
