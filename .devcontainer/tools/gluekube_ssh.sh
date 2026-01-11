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
        local gh_org="development-captains"
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
                    mode=$(gum choose --header="What would you like to do?" "📦 Clone GitHub Repo ($matched_repo)" "◀ Back" || true)
                    
                    case "$mode" in
                        📦*)
                            clone_repo_mode "$matched_repo" "development-captains"
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
            
            # Collect all unique SSH key IDs from the cluster
            local all_ssh_key_ids
            all_ssh_key_ids=$(echo "$cluster" | jq -r '[.bastion_server.ssh_key_id, .node_pools[].servers[].ssh_key_id] | unique | .[] | select(. != null and . != "")' | tr '\n' ' ')
            
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
                servers="BASTION|$bastion_hostname|$bastion_status|$bastion_ip|$bastion_private_ip"
            fi
            
            # Add node pool servers
            local node_servers
            node_servers=$(echo "$cluster" | jq -r '.node_pools[].servers[] | "\(.role | ascii_upcase)|\(.hostname)|\(.status)|\(.public_ip_address // "N/A")|\(.private_ip_address // "N/A")"' 2>/dev/null || true)
            
            if [[ -n "$node_servers" ]]; then
                if [[ -n "$servers" ]]; then
                    servers="$servers"$'\n'"$node_servers"
                else
                    servers="$node_servers"
                fi
            fi
            
            # Mode selection loop
            while true; do
                clear
                local mode
                local menu_options=()
                
                # Only add SSH/kubectl/kubeconfig options if bastion exists
                if [[ -n "$bastion_ip" ]] && [[ -n "$servers" ]]; then
                    menu_options+=("🔗 SSH to servers" "📡 Port forward to master (6443)" "⚙️ Setup ~/.kube/config")
                fi
                
                # Add clone option if there's a matched repo
                if [[ -n "$matched_repo" ]]; then
                    menu_options+=("📦 Clone GitHub Repo ($matched_repo)")
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
                    "🔗 SSH to servers")
                        ssh_mode "$cluster_id" "$bastion_ip" "$servers" "$org_id" "$all_ssh_key_ids"
                        ;;
                    "📡 Port forward to master (6443)")
                        kubectl_mode "$cluster_id" "$bastion_ip" "$servers" "$org_id" "$all_ssh_key_ids"
                        ;;
                    "⚙️ Setup ~/.kube/config")
                        kubeconfig_mode "$cluster_id" "$bastion_ip" "$servers" "$org_id" "$all_ssh_key_ids"
                        ;;
                    📦*)
                        clone_repo_mode "$matched_repo" "development-captains"
                        ;;
                    "◀ Back")
                        break
                        ;;
                esac
            done
        done
    done
}

# Load SSH keys to agent (called on demand)
load_ssh_keys() {
    local org_id="$1"
    local ssh_key_ids="$2"  # space-separated list of key IDs
    
    if [[ -z "$ssh_key_ids" ]]; then
        return 0
    fi
    
    # Check if ssh-agent is running (exit code 2 = not running, 0/1 = running)
    local agent_status=0
    ssh-add -l >/dev/null 2>&1 || agent_status=$?
    if [[ $agent_status -eq 2 ]]; then
        eval $(ssh-agent) > /dev/null
    fi
    
    # Load each unique SSH key
    local loaded=0
    local failed=0
    for key_id in $ssh_key_ids; do
        local key_data
        key_data=$(api_call GET "/ssh/$key_id?reveal=true" "$org_id" 2>/dev/null)
        local private_key
        private_key=$(echo "$key_data" | jq -r '.private_key' 2>/dev/null)
        
        # Add to ssh-agent
        echo "$private_key" | ssh-add - >/dev/null 2>&1
    done
}

# SSH mode - show all servers, connect directly when selected
ssh_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    local org_id="$4"
    local ssh_key_ids="$5"
    
    local key_loaded=false
    
    # Server selection loop
    while true; do
        clear
        # Build formatted server list
        local server_list=""
        while IFS='|' read -r role hostname status public_ip private_ip; do
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
        
        # Get the full server line to extract role and IPs
        local server_line
        server_line=$(echo "$servers" | grep -F "|$hostname|")
        
        local role
        role=$(echo "$server_line" | cut -d'|' -f1)
        local private_ip
        private_ip=$(echo "$server_line" | cut -d'|' -f5)
        local public_ip
        public_ip=$(echo "$server_line" | cut -d'|' -f4)
        
        local target_ip
        if [[ -n "$private_ip" ]] && [[ "$private_ip" != "N/A" ]]; then
            target_ip="$private_ip"
        else
            target_ip="$public_ip"
        fi
        
        # Load SSH key on first connection
        if [[ "$key_loaded" == "false" ]]; then
            load_ssh_keys "$org_id" "$ssh_key_ids"
            key_loaded=true
        fi
        
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
    local ssh_key_ids="$5"
    
    local key_loaded=false
    
    # Filter to only master nodes
    local master_servers
    master_servers=$(echo "$servers" | grep "^MASTER|")
    
    if [[ -z "$master_servers" ]]; then
        echo "No master nodes found"
        return
    fi
    
    # Master selection loop
    while true; do
        # Format for display
        local server_list
        server_list=$(echo "$master_servers" | awk -F'|' '{printf "[%s] %s (%s)\n", $1, $2, $3}')
        
        local server_selection
        server_selection=$(echo -e "$server_list\n◀ Back" | gum choose --header="Select master node for kubectl:" || true)
        
        # Handle ESC or Back
        if [[ -z "$server_selection" ]] || [[ "$server_selection" == "◀ Back" ]]; then
            return
        fi
        
        # Extract hostname
        local hostname
        hostname=$(echo "$server_selection" | sed -n 's/.*] \([^ ]*\).*/\1/p')
        
        # Get the IP for this server - prefer private, fallback to public
        local server_line
        server_line=$(echo "$master_servers" | grep "|$hostname|")
        local private_ip
        private_ip=$(echo "$server_line" | cut -d'|' -f5)
        local public_ip
        public_ip=$(echo "$server_line" | cut -d'|' -f4)
        
        local target_ip
        if [[ -n "$private_ip" ]] && [[ "$private_ip" != "N/A" ]]; then
            target_ip="$private_ip"
        else
            target_ip="$public_ip"
        fi
        
        # Load SSH key on first port forward
        if [[ "$key_loaded" == "false" ]]; then
            load_ssh_keys "$org_id" "$ssh_key_ids"
            key_loaded=true
        fi
        
        # Port forward directly - after Ctrl+C, returns to master list
        port_forward "$bastion_ip" "$cluster_id" "$hostname" "$target_ip" || true
    done
}

# kubeconfig mode - copy admin.conf from master to ~/.kube/config
kubeconfig_mode() {
    local cluster_id="$1"
    local bastion_ip="$2"
    local servers="$3"
    local org_id="$4"
    local ssh_key_ids="$5"
    
    # Filter to only master nodes
    local master_servers
    master_servers=$(echo "$servers" | grep "^MASTER|")
    
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
    server_line=$(echo "$master_servers" | grep "|$hostname|")
    local private_ip
    private_ip=$(echo "$server_line" | cut -d'|' -f5)
    local public_ip
    public_ip=$(echo "$server_line" | cut -d'|' -f4)
    
    local target_ip
    if [[ -n "$private_ip" ]] && [[ "$private_ip" != "N/A" ]]; then
        target_ip="$private_ip"
    else
        target_ip="$public_ip"
    fi
    
    # Create ~/.kube directory if it doesn't exist
    mkdir -p ~/.kube
    
    # Load SSH keys before copying
    load_ssh_keys "$org_id" "$ssh_key_ids"
    
    echo "Fetching kubeconfig from $hostname..."
    
    # Copy the file through bastion using double-hop SCP with agent forwarding and private IP
    if ssh -A -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t cluster@"$bastion_ip" \
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR cluster@$target_ip \
        'sudo cat /etc/kubernetes/admin.conf'" > ~/.kube/config 2>&1; then
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

# Clone GitHub repo mode
clone_repo_mode() {
    local repo_name="$1"
    local org="$2"
    
    if [[ -z "$repo_name" ]]; then
        return
    fi
    
    # Check if directory already exists
    if [[ -d "$repo_name" ]]; then
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
            
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
        else
            echo "Directory '$repo_name' already exists (not a git repository)"
            echo ""
            read -n 1 -s -r -p "Press any key to continue..." || true
            echo ""
        fi
        return
    fi
    
    gh repo clone "$org/$repo_name" "$repo_name" 2>&1
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
        
        # Use agent forwarding with private IP address
        ssh -A -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -t cluster@"$bastion_ip" \
            "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR cluster@$target_ip"
    fi
}

port_forward() {
    local bastion_ip="$1"
    local cluster_id="$2"
    local hostname="$3"
    local target_ip="${4:-}"
    
    local port="6443"
    
    echo "Starting port forward: localhost:$port -> $hostname:6443"
    echo "Press Ctrl+C to stop forwarding"
    echo ""
    
    # Double hop: laptop->bastion->target, both with -L forwarding
    # Use agent forwarding with private IP address
    ssh -A -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ExitOnForwardFailure=yes \
        -L "$port:localhost:$port" -t cluster@"$bastion_ip" \
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -N -L $port:localhost:6443 cluster@$target_ip"
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
    
    # Browse infrastructure - will loop internally until user exits
    browse_infrastructure
}

main "$@"
