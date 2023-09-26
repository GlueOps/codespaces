#!/bin/bash

tools_file="/etc/tools.sh"

add_tools_to_shell() {
    local rc_file="$1"
    if [ -f "$rc_file" ]; then
        echo "source $tools_file" >> "$rc_file"
    fi
}

# bash
add_tools_to_shell "$HOME/.bashrc"

# zsh
add_tools_to_shell "$HOME/.zshrc"
