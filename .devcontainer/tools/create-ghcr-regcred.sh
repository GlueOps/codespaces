#!/bin/bash

gh_username=""
gh_token=""

# Parse flags
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    (-u|--github-username)
      gh_username="$2"
      shift
      shift
      ;;
    (-t|--github-token)
      gh_token="$2"
      shift
      shift
      ;;
    (--help)
      echo "Usage: create-ghcr-regcred [options]"
      echo ""
      echo "Options:"
      echo "  -u, --github-username VALUE   The github username associated with the token"
      echo "  -t, --github-token VALUE      The github token that enables pull access to ghcr"
      echo "  --help                        Show this help message and exit"
      exit 0
      ;;
    (*)
      echo "Unknown option: $key"
      echo "Run 'create-ghcr-regcred --help' for usage information."
      exit 1
      ;;
  esac
done

# Check if required arguments were provided
if [[ -z $gh_username || -z $gh_token ]]; then
    echo "Error: Both --github-username and --github-token are required."
    echo "Run 'create-ghcr-regcred --help' for usage information."
    exit 1
fi

set -e
b64_enc_regcred=$(echo -n "$gh_username:$gh_token" | base64)

echo "{\"auths\":{\"ghcr.io\":{\"auth\":\"$b64_enc_regcred\"}}}"