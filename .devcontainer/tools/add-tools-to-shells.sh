#!/bin/bash

add_tools_to_shells() {
    if [ -f "/home/vscode/.bashrc" ]; then
        find /etc/tools/ -type f ! -name "add-tools-to-shells.sh" ! -name "helm-repositories.yaml" \
            -exec sh -c 'echo >> /home/vscode/.bashrc; cat "{}" >> /home/vscode/.bashrc' \;
        echo "zsh" >> /home/vscode/.bashrc
    fi

    if [ -d "/home/vscode/.oh-my-zsh/custom" ]; then
        find /etc/tools/ -type f ! -name "add-tools-to-shells.sh" ! -name "helm-repositories.yaml" -name "*.sh" \
            -exec sh -c 'file="{}"; cp "$file" "/home/vscode/.oh-my-zsh/custom/$(basename ${file%.sh}.zsh)"' \;
    fi


}

add_tools_to_shells
