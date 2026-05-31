#!/bin/bash
set -e -o pipefail

echo "waiting for cloud-init to finish..."
sudo cloud-init status --wait

echo "disk layout and free space:"
df -h /
lsblk

echo "update packages..."
sudo apt-get update

