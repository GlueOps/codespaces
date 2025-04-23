#!/bin/bash

# Check if log4brains is installed globally (silently)
if ! npm list -g --depth=0 2>/dev/null | grep -q log4brains; then
  # log4brains not found, install it
  echo "log4brains not found globally. Installing now..." >&2 # Print installation message to stderr
  if ! npm install -g log4brains; then
    echo "Error: Failed to install log4brains." >&2 # Print error message to stderr
    exit 1
  fi
fi

# Execute the log4brains command with all arguments passed to this script
log4brains "$@"
