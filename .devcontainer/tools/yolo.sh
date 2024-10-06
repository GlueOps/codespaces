#!/bin/bash

# Always unset GITHUB_TOKEN
unset GITHUB_TOKEN

# If the file doesn't exist or 'gh auth status' returns an exit code of 1
if [[ ! -f /home/vscode/.config/gh/hosts.yml ]] || ! gh auth status &>/dev/null; then
    # If the file doesn't exist or 'gh auth status' fails, then proceed with the rest of the script

    # Run the gh auth login command
    yes Y | gh auth login -h github.com -p https -w -s repo,workflow,admin:org,write:packages,user,gist,notifications,admin:repo_hook,admin:public_key,admin:enterprise,audit_log,codespace,project,admin:gpg_key,admin:ssh_signing_key

    echo "Set up git with gh auth"
    gh auth setup-git

    # Configure git config
    git_email=$(gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" /user/emails | jq '.[] | select(.primary == true) | .email' -r)
    git_name=$(gh api user | jq '.name' -r)
    git config --global user.email "${git_email}"
    git config --global user.name "${git_name}"
    git config --global core.autocrlf input
else
    echo "GitHub authentication is already set up."
    gh auth status
fi