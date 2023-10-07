#!/bin/bash

add_tools_to_shells() {
    if [ -f "/home/vscode/.bashrc" ]; then
        find /tmp/tools/ -type f ! -name "add-tools-to-shells.sh" \
            -exec sh -c 'echo >> /home/vscode/.bashrc; cat "{}" >> /home/vscode/.bashrc' \;
    fi

    if [ -d "/home/vscode/.oh-my-zsh/custom" ]; then
        find . -type f ! -name "add-tools-to-shells.sh" -name "*.sh" \
            -exec sh -c 'file="{}"; cp "$file" "/home/vscode/.oh-my-zsh/custom/$(basename ${file%.sh}.zsh)"' \;
    else
        echo "/home/vscode/.oh-my-zsh/custom does not exist" >> /home/vscode/error_log.txt
    fi


}

add_tools_to_shells
