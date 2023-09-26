#!/bin/bash

tools_file="/etc/tools.sh"

add_tools_to_shell() {
    local file="$1"
    if [ -f "$file" ]; then
        echo "source $tools_file" >> "$file"
    fi
}

# bash
add_tools_to_shell "$HOME/.bashrc"

# zsh
add_tools_to_shell "$HOME/.zshrc"


# Add more shells as needed
# add_tools_to_shells "shell_cmd" "shell_config_file" "shell_global_config_file"
