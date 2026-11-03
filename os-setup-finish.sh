#!/bin/bash
set -e -o pipefail

# --- Make cloud-init run on Incus VMs -----------------------------------------
# On Incus, cloud-init's ds-identify generator runs very early in boot — before the incus-agent
# presents the datasource over vsock — so it finds nothing and DISABLES cloud-init
# (`disabled-by-generator`). Result on Incus: no netplan is written, the NIC never comes up, and
# user-data never runs. libvirt/Proxmox/QEMU don't hit this because they attach a cidata seed disk
# that ds-identify sees immediately (the same way this Packer build's own `cd_label=cidata` works).
#
# This policy tells ds-identify NOT to disable cloud-init when it finds no datasource early; cloud-init
# then discovers the LXD/Incus datasource at its normal stages (via the already-installed incus-agent).
# It is INERT everywhere a datasource IS found early (libvirt/Proxmox/bare-metal cidata): the
# `notfound` branch simply never triggers, so those platforms behave exactly as before.
sudo install -d -m 0755 /etc/cloud /etc/cloud/cloud.cfg.d
printf 'policy: search,found=all,maybe=all,notfound=enabled\n' | sudo tee /etc/cloud/ds-identify.cfg >/dev/null
# The policy above intentionally lets cloud-init run when ds-identify reported no source, which emits a
# cosmetic "dsid_missing_source" warning on Incus (source was [], but LXD was used). Silence just that.
printf 'warnings:\n  dsid_missing_source: off\n' | sudo tee /etc/cloud/cloud.cfg.d/99-warnings.cfg >/dev/null

# The provisioner attaches the cidata seed only for the first boot (virt-install --cloud-init; Proxmox ejects
# it). Without this, every later boot re-runs datasource discovery: ~6 min of probe timeouts, then cloud-init
# falls back to DataSourceNone and treats the VM as new (SSH host keys regenerated). With it, cloud-init reuses
# what it found on first boot; the cloud-init clean below still makes every new VM discover normally.
printf 'manual_cache_clean: true\n' | sudo tee /etc/cloud/cloud.cfg.d/99-manual-cache-clean.cfg >/dev/null

echo "cleaning up"
sudo cloud-init clean --machine-id --seed --logs
sudo rm -rvf /var/lib/cloud/instances /etc/machine-id /var/lib/dbus/machine-id /var/log/cloud-init*
# AWS seems to have issues if the /etc/machine-id file is removed
sudo touch /etc/machine-id
sudo rm /root/.ssh/authorized_keys || true
sudo rm /home/admin/.ssh/authorized_keys || true
