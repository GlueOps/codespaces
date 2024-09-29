#!/bin/bash
set -e -o pipefail

echo "cleaning up"
sudo cloud-init clean --machine-id --seed --logs
sudo rm -rvf /var/lib/cloud/instances /etc/machine-id /var/lib/dbus/machine-id /var/log/cloud-init*
# AWS seems to have issues if the /etc/machine-id file is removed
sudo touch /etc/machine-id
sudo rm /root/.ssh/authorized_keys || true
sudo rm /home/admin/.ssh/authorized_keys || true
