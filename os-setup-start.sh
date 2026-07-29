#!/bin/bash
set -e -o pipefail

echo "waiting for cloud-init to finish..."
sudo cloud-init status --wait

echo "disk layout and free space:"
df -h /
lsblk

echo "update packages..."
# --error-on=any: fail the build if ANY apt source errors, rather than silently
# proceeding with a stale/partial index and shipping a subtly-broken image.
sudo apt-get update --error-on=any

