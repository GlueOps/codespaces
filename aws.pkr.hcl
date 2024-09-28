variable "aws_access_key" {
  type = string
}

variable "aws_secret_key" {
  type = string
}

#https://github.com/GlueOps/codespaces/pkgs/container/codespaces
variable "glueops_codespaces_container_tag" {
  type    = string
}

source "amazon-ebs" "cde" {
  access_key = "${var.aws_access_key}"
  secret_key = "${var.aws_secret_key}"
  region     = "us-west-2"
  source_ami_filter {
    filters = {
      virtualization-type = "hvm"
      name                = "debian-12-amd64-*"
      root-device-type    = "ebs"
    }
    owners      = ["136693071363"]
    most_recent = true
  }
  instance_type = "t3a.large"
  ssh_username  = "admin"
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }
  ami_virtualization_type = "hvm"
  ami_regions             = ["us-west-2", "us-east-2", "ap-south-1", "eu-central-1" ]

  ami_name = "${var.glueops_codespaces_container_tag}"
}

build {
  sources = ["source.amazon-ebs.cde"]

  provisioner "shell" {
    inline = [
      "wget http://archive.ubuntu.com/ubuntu/pool/main/e/ec2-instance-connect/ec2-instance-connect_1.1.17-0ubuntu1_all.deb",
      "sudo dpkg -i ec2-instance-connect_1.1.17-0ubuntu1_all.deb",
    ]
  }

  provisioner "shell" {
    scripts = [
      "os-setup.sh",
    ]
    env = {
      BUILDER = "packer"
    }
  }

  provisioner "shell" {
    inline = [
      "sudo docker pull ghcr.io/glueops/codespaces:${var.glueops_codespaces_container_tag}",
    ]
  }

}

packer {
  required_plugins {
    hcloud = {
      source  = "github.com/hashicorp/amazon"
      version = "1.3.3"
    }
  }
}
