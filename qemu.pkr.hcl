variable "glueops_codespaces_container_tag" {
  type    = string
}

variable "image_password" {
  type    = string
}

source "qemu" "qemu-amd64" {
  accelerator       = "kvm"
  iso_url           = "https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2"
  iso_checksum      = "file:https://cloud.debian.org/images/cloud/trixie/daily/latest/SHA512SUMS"
  disk_image        = true
  output_directory  = "images"
  disk_size         = 20000
  format            = "qcow2"
  vm_name           = "${var.glueops_codespaces_container_tag}.qcow2"
  ssh_username      = "debian"
  ssh_password      = "${var.image_password}"
  shutdown_command  = "sudo fstrim -av && sudo shutdown -P now"
  headless          = true
  ssh_wait_timeout  = "5m"
  vnc_port_min      = 5901
  vnc_port_max      = 5901
  cd_files          = ["user-data", "meta-data"]
  cd_label          = "cidata"
  qemuargs          = [
    ["-m", "12288M"],
    ["-smp", "4"]
  ]
}

build {
  sources = ["source.qemu.qemu-amd64"]

  # vm/ holds the files vm/observability.sh installs (collector config, systemd drop-in, node exporter defaults).
  # Uploaded as a directory into /tmp, so the scripts below find them at /tmp/vm.
  provisioner "file" {
    source      = "vm"
    destination = "/tmp"
  }

  provisioner "shell" {
    scripts = [
      "os-setup-start.sh",
      "developer-setup.sh",
      "vm/observability.sh",
      "os-setup-finish.sh",
    ]
    environment_vars = [
      "GLUEOPS_CODESPACES_CONTAINER_TAG=${var.glueops_codespaces_container_tag}"
    ]
  }

  provisioner "shell" {
    inline = [
      # Clean up apt
      "sudo apt-get -y autoremove",
      "sudo apt-get -y clean",
      "sudo rm -rf /var/lib/apt/lists/*",

      # Clear logs
      "sudo find /var/log -type f -name '*.log' -delete",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "qemu-img convert -O qcow2 -c images/${var.glueops_codespaces_container_tag}.qcow2 images/${var.glueops_codespaces_container_tag}-compressed.qcow2",
      "rm user-data",
      "rm meta-data",
      "rm images/${var.glueops_codespaces_container_tag}.qcow2",
      "mv images/${var.glueops_codespaces_container_tag}-compressed.qcow2 images/${var.glueops_codespaces_container_tag}.qcow2"
    ]
  }
}

packer {
    required_plugins {
        qemu = {
        source  = "github.com/hashicorp/qemu"
        version = "1.1.0"
        }
    }
}
