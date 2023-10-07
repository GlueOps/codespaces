#!/bin/bash

yolo() {
    # Always unset GITHUB_TOKEN
    unset GITHUB_TOKEN

    # If the file doesn't exist or 'gh auth status' returns an exit code of 1
    if [[ ! -f /home/vscode/.config/gh/hosts.yml ]] || ! gh auth status; then
        # If the file doesn't exist or 'gh auth status' fails, then proceed with the rest of the script

        # Run the gh auth login command
        yes Y | gh auth login -h github.com -p https -w -s repo,workflow,admin:org,write:packages,user,gist,notifications,admin:repo_hook,admin:public_key,admin:enterprise,audit_log,codespace,project,admin:gpg_key,admin:ssh_signing_key

        echo "Set up git with gh auth"
        gh auth setup-git
    fi
}
