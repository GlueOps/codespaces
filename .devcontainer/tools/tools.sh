#!/bin/bash

run-gha() {
    #https://stackoverflow.com/questions/6245570/how-do-i-get-the-current-branch-name-in-git
    gh workflow run --ref=$(git rev-parse --abbrev-ref HEAD)
}

glueops-fetch-repos() {
    #https://stackoverflow.com/a/68770988/4620962
    
    gh repo list $(git remote get-url origin | cut -d/ -f4) --no-archived --limit 1000 | while read -r repo _; do
      gh repo clone "$repo" "$repo" -- --depth=1 --recurse-submodules || {
        git -C $repo pull
      } &
    done
}

yolo() {
    # Always unset GITHUB_TOKEN
    unset GITHUB_TOKEN

    # If the file doesn'"'"'t exist or '"'"'gh auth status'"'"' returns an exit code of 1
    if [[ ! -f /home/vscode/.config/gh/hosts.yml ]] || ! gh auth status; then
        # If the file doesn'"'"'t exist or '"'"'gh auth status'"'"' fails, then proceed with the rest of the script

        # Run the gh auth login command
        yes Y | gh auth login -h github.com -p https -w -s repo,workflow,admin:org,write:packages,user,gist,notifications,admin:repo_hook,admin:public_key,admin:enterprise,audit_log,codespace,project,admin:gpg_key,admin:ssh_signing_key

        echo "Set up git with gh auth"
        gh auth setup-git
    fi
}


create-ghcr-regcred() {
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
          echo "  -t, --github-token VALUE  The github token that enables pull access to ghcr"
          echo "  --help                    Show this help message and exit"
          return
          ;;
        (*)
          echo "Unknown option: $key"
          echo "Run 'create-ghcr-regcred --help' for usage information."
          return
          ;;
      esac
    done

    # Check if version arguments were provided
    if [[ -z $gh_username || -z $gh_token ]]; then
        echo "Both arguments are required."
        echo "Run 'create-ghcr-regcred --help' for usage information."
        return
    fi

    set -e
    b64_enc_regcred=$(echo -n "$gh_username:$gh_token" | base64)

    echo "{\"auths\":{\"ghcr.io\":{\"auth\":\"$b64_enc_regcred\"}}}"
}
