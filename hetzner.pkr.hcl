# custom-img-v2.pkr.hcl
variable "base_image" {
  type    = string
  default = "debian-12"
}

variable "glueops_codespaces_container_tag" {
  type = string
}

source "hcloud" "base-amd64" {
  image         = var.base_image
  location      = "nbg1"
  server_type   = "cx22"
  server_name   = "packer-${var.glueops_codespaces_container_tag}"
  ssh_username  = "root"
  snapshot_name = "${var.glueops_codespaces_container_tag}"
  snapshot_labels = {
    base    = var.base_image,
    version = var.glueops_codespaces_container_tag
  }
}

build {
  sources = ["source.hcloud.base-amd64"]
  provisioner "shell" {
    scripts = [
      "os-setup-start.sh",
      "developer-setup.sh",
      "os-setup-finish.sh",
    ]
    env = {
      BUILDER = "packer"
      GLUEOPS_CODESPACES_CONTAINER_TAG = var.glueops_codespaces_container_tag
    }
  }
}

# packer.pkr.hcl
packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hetznercloud/hcloud"
      version = "1.6.0"
    }
  }
}
