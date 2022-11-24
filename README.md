# codespaces


This repo contains all the environmental tools/dependencies to deploy the entire glueops platform. Tools include but are not limited to: terraform, helm, kubectl, etc. We primarily use this repository in all of our codespaces. Ref: https://github.com/GlueOps/glueops/blob/%F0%9F%9A%80%F0%9F%92%8E%F0%9F%99%8C%F0%9F%9A%80/.devcontainer/devcontainer.json#L5


Releasing:
- Please stick to semver standards when dropping a new tag.
- Once you publish a release a new image will be built and uploaded to dockerhub: https://hub.docker.com/r/glueops/codespaces/tags
