#!/bin/zsh

cordon-drain-nodes-older-than-minutes() {
    threshold_minutes=""

    while [[ $# -gt 0 ]]; do
      key="$1"
      case $key in
        (-m|--threshold-minutes)
          threshold_minutes="$2"
          shift
          shift
          ;;
        (--help)
          echo "Usage: cordon-drain-nodes-older-than-minutes [options]"
          echo ""
          echo "Options:"
          echo "  -m, --threshold-minutes VALUE   Target nodes older than this many minutes."
          echo "  --help                    Show this help message and exit"
          return
          ;;
        (*)
          echo "Unknown option: $key"
          echo "Run 'cordon-drain-nodes-older-than-minutes --help' for usage information."
          return
          ;;
      esac
    done


    CURRENT_DATE=$(date +%s)

    NODES=$(kubectl get nodes -o json | jq --arg CURRENT_DATE "$CURRENT_DATE" --arg THRESHOLD_MINUTES "$threshold_minutes" -r '
    .items[] |
    select(
        .metadata.creationTimestamp | fromdateiso8601 < ($CURRENT_DATE | tonumber) - ($THRESHOLD_MINUTES | tonumber * 60)
    ) | .metadata.name')

    if [ -z "$NODES" ]; then
        echo "No nodes older than $threshold_minutes minutes found."
        exit 0
    fi

    echo "Nodes found older than $threshold_minutes minutes:"
    echo "$NODES"
    echo ""

    echo -n "Cordon the listed nodes? (y/N) "
    read response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "$NODES" | while IFS= read -r node; do
            echo "Cordoning node: $node"
            kubectl cordon "$node"
            echo ""
        done
    else
        echo "Cordoning skipped.  Will not attempt to drain."
        return 0
    fi

    echo -n "Drain the cordoned nodes? (y/N) "
    read response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "$NODES" | while IFS= read -r node; do
            echo "Draining node: $node"
            kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data > "drain-${node}.log" 2>&1 &
        done
        wait
        echo "All nodes drained."
    else
        echo "Draining skipped."
    fi

}
