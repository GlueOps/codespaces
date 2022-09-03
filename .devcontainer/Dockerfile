# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.233.0/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
ARG VARIANT="jammy"
FROM mcr.microsoft.com/vscode/devcontainers/base:0-${VARIANT}

# [Optional] Uncomment this section to install additional OS packages.
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#     && apt-get -y install --no-install-recommends <your-package-list-here>


ENV CLOUDSDK_INSTALL_DIR /usr/local/gcloud/
RUN curl -sSL https://sdk.cloud.google.com | bash
ENV PATH $PATH:/usr/local/gcloud/google-cloud-sdk/bin
RUN gcloud components install gke-gcloud-auth-plugin --quiet
RUN gcloud components install alpha --quiet
RUN gcloud components install beta --quiet
RUN sh -c "$(curl --location https://raw.githubusercontent.com/go-task/task/v3.14.1/install-task.sh)" -- -d -b /usr/local/bin/
RUN curl https://stedolan.github.io/jq/download/linux64/jq > /usr/local/bin/jq && sudo chmod +x /usr/local/bin/jq
RUN apt update && apt install tmux -y && apt clean -y
RUN curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/v2.4.11/argocd-linux-amd64
RUN chmod +x /usr/local/bin/argocd



# https://github.com/microsoft/vscode-dev-containers/blob/main/containers/docker-in-docker/.devcontainer/Dockerfile#L31-L37
VOLUME [ "/var/lib/docker" ]

# Setting the ENTRYPOINT to docker-init.sh will start up the Docker Engine 
# inside the container "overrideCommand": false is set in devcontainer.json. 
# The script will also execute CMD if you need to alter startup behaviors.
ENTRYPOINT [ "/usr/local/share/docker-init.sh" ]
CMD [ "sleep", "infinity" ]
