function gluekube_ssh() {
    local BASTION_HOST="$1"
    local TARGET_IP="$2"
    local LOCAL_PEM="$3"
    shift 3 
    
    local OUTER_ARGS=("$@")

    if [[ -z "$BASTION_HOST" || -z "$TARGET_IP" || -z "$LOCAL_PEM" ]]; then
        echo "Usage: gluekube_ssh <BASTION_IP> <TARGET_IP> <LOCAL_PEM> [SSH_FLAGS]"
        echo "gluekube_ssh 157.180.22.11 157.180.11.11 bastion.pem -L 6443:127.0.0.1:6443"
        return 1
    fi

    # --- 1. Filter Arguments for the Inner Jump ---
    # We strip out flags meant for the laptop-to-bastion connection
    # and only keep tunneling/option flags for the bastion-to-target connection.
    local INNER_ARGS=""
    local i=0
    local argc=${#OUTER_ARGS[@]}
    
    while [ $i -lt $argc ]; do
        arg="${OUTER_ARGS[$i]}"
        # If we see -L, -R, -D, or -o, copy them to the inner command.
        # CRITICAL FIX: We do NOT add quotes around the values here.
        if [[ "$arg" == "-L" || "$arg" == "-R" || "$arg" == "-D" || "$arg" == "-o" ]]; then
            next_arg="${OUTER_ARGS[$i+1]}"
            INNER_ARGS="$INNER_ARGS $arg $next_arg"
            ((i++)) 
        fi
        ((i++))
    done

    # --- 2. The Command ---
    # We use UserKnownHostsFile=/dev/null to fix the "Permission denied" and "Host check" errors.
    # We define the remote options strictly inside the remote block to avoid quote errors.
    
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$LOCAL_PEM" "${OUTER_ARGS[@]}" -t cluster@$BASTION_HOST "
        
        TARGET='$TARGET_IP'
        KEY_DIR=\"\$HOME/.ssh/autoglue/keys\"
        
        # Hardcoded remote options to guarantee syntax validity
        # We point UserKnownHostsFile to /dev/null so it never tries to read/write the broken file on the bastion
        REMOTE_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
        
        # Combine hardcoded opts with your dynamic tunnels
        FINAL_OPTS=\"\$REMOTE_OPTS $INNER_ARGS\"

        echo \"🔎 Search target: cluster@\$TARGET\"
        
        # Check for keys
        count=\$(ls \$KEY_DIR/*.pem 2>/dev/null | wc -l)
        if [ \"\$count\" -eq 0 ]; then
             echo \"❌ No .pem files found in \$KEY_DIR\"
             exit 1
        fi

        for key in \$KEY_DIR/*.pem; do
            # Test connection (Quietly)
            ssh -q -o BatchMode=yes -o ConnectTimeout=2 \$REMOTE_OPTS -i \"\$key\" cluster@\$TARGET \"exit\" >/dev/null 2>&1
            
            if [ \$? -eq 0 ]; then
                echo '✅ MATCH: ' \$(basename \"\$key\")
                echo '🚀 Connecting...'
                # Execute final connection
                exec ssh \$FINAL_OPTS -i \"\$key\" cluster@\$TARGET
            fi
        done
        echo '❌ No working key found.'
    "
}
