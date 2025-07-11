variable "glueops_codespaces_container_tag" {
  type    = string
}

variable "image_password" {
  type    = string
}

source "qemu" "qemu-amd64" {
  iso_url           = "https://cloud.debian.org/images/cloud/bookworm/daily/latest/debian-12-generic-amd64-daily.qcow2"
  iso_checksum      = "file:https://cloud.debian.org/images/cloud/bookworm/daily/latest/SHA512SUMS"
  disk_image        = true
  output_directory  = "images"
  disk_size         = 10000
  format            = "qcow2"
  vm_name           = "${var.glueops_codespaces_container_tag}.qcow2"
  ssh_username      = "debian"
  ssh_password      = "${var.image_password}"
  shutdown_command  = "echo 'packer' | sudo -S shutdown -P now"
  headless          = true
  ssh_wait_timeout  = "5m"
  vnc_port_min      = 5901
  vnc_port_max      = 5901
  qemuargs          = [
    ["-m", "4096M"],
    ["-smp", "2"],
    ["-cdrom", "ci-data.iso"]
  ]
}

build {
  sources = ["source.qemu.qemu-amd64"]

  provisioner "shell" {
    scripts = [
      "os-setup-start.sh",
      "developer-setup.sh",
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

      # Zero out free space to reduce image size
      "sudo dd if=/dev/zero of=/EMPTY bs=1M || true",
      "sudo sync",
      "sudo rm -f /EMPTY",
    ]
  }

  post-processor "shell-local" {
    inline = [
      "qemu-img convert -O qcow2 -c images/${var.glueops_codespaces_container_tag}.qcow2 images/${var.glueops_codespaces_container_tag}-compressed.qcow2",
      "rm ci-data.iso",
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
