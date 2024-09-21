#!/bin/bash
set -e -o pipefail

echo "waiting for cloud-init to finish..."
cloud-init status --wait

echo "installing packages..."
apt-get update
echo "installing tailscale"
curl -fsSL https://tailscale.com/install.sh | sh
curl -sL setup.glueops.dev | sh

# My setup...

echo "cleaning up"
cloud-init clean --machine-id --seed --logs
rm -rvf /var/lib/cloud/instances /etc/machine-id /var/lib/dbus/machine-id /var/log/cloud-init*