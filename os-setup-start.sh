#!/bin/bash
set -e -o pipefail

echo "waiting for cloud-init to finish..."
sudo cloud-init status --wait

echo "update packages..."
sudo apt-get update

