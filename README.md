# codespaces

## Description: 

This repo contains all the environmental tools/dependencies to deploy the entire glueops platform. Tools include but are not limited to: terraform, helm, kubectl, etc. We primarily use this repository in all of our codespaces as well as github actions. Ref: https://github.com/GlueOps/glueops/blob/%F0%9F%9A%80%F0%9F%92%8E%F0%9F%99%8C%F0%9F%9A%80/.devcontainer/devcontainer.json#L5


# Releasing:
- Please stick to semver standards when dropping a new tag.
- Once you publish a release a new image will be built and uploaded to GHCR: https://github.com/GlueOps/codespaces/pkgs/container/codespaces



# Running packer locally:

It's best to just reference the github workflows under `.github/workflows` the packer workflows for each respective cloud start with `packer-*`. For each respective cloud you will notice env variables are being passed into a github action step. To do this locally, you will need to create credentials for the respective cloud and then `export` the applicable environment variables before running the `packer build` command.


### Running AWS:


```bash
export AWS_ACCESS_KEY_ID="XXXXXXXXXXXXXXXXX"
export AWS_SECRET_ACCESS_KEY="XXXXXXXXXXXXXXXXX"
packer init aws.pkr.hcl
packer build -var glueops_codespaces_container_tag=v0.52.0 aws.pkr.hcl
```

### Running Hetzner

```bash
export HCLOUD_TOKEN="XXXXXXXXXXXXXXXXX"
packer init hetzner.pkr.hcl
packer build -var glueops_codespaces_container_tag=v0.52.0 hetzner.pkr.hcl
```


_Note: v0.52.0 is the latest version at the time of creating this README.md you can check for the latest version here: https://github.com/GlueOps/codespaces/releases
