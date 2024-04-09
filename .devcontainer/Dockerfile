# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.233.0/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
#https://mcr.microsoft.com/v2/devcontainers/base/tags/list
#https://github.com/devcontainers/images/tree/main/src/base-ubuntu
FROM mcr.microsoft.com/vscode/devcontainers/base:0-ubuntu-22.04

# [Optional] Uncomment this section to install additional OS packages.
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#     && apt-get -y install --no-install-recommends <your-package-list-here>

ARG VERSION_KUBECTL=1.27.11
ARG VERSION_OPENTOFU=1.6.2
ARG VERSION_HELM=3.14.3
ARG VERSION_GCLOUD_SDK=468.0.0
ARG VERSION_TASKFILE=3.35.1
ARG VERSION_KIND=0.22.0
ARG VERSION_K9S=0.32.3
ARG VERSION_TERRAFORM_DOCS=0.17.0
ARG VERSION_KUBENT=0.7.2
ARG VERSION_HELM_DIFF=3.9.5
ARG VERSION_CHARM_GUM=0.13.0
ARG VERSION_ARGO_CD_CLI=2.9.9
ARG VERSION_K3D=5.6.0

# https://developer.hashicorp.com/vault/docs/commands#vault_skip_verify
# https://github.com/GlueOps/terraform-module-kubernetes-hashicorp-vault-configuration/wiki
ENV VAULT_SKIP_VERIFY true
ENV CLOUDSDK_INSTALL_DIR /usr/local/gcloud/

COPY tools/ /etc/tools
RUN chmod +x /etc/tools/add-tools-to-shells.sh && ./etc/tools/add-tools-to-shells.sh
RUN curl -Lo /usr/local/bin/kubectl https://dl.k8s.io/release/v${VERSION_KUBECTL}/bin/linux/amd64/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -Lo tofu_${VERSION_OPENTOFU}_linux_amd64.zip https://github.com/opentofu/opentofu/releases/download/v${VERSION_OPENTOFU}/tofu_${VERSION_OPENTOFU}_linux_amd64.zip \
    && unzip tofu_${VERSION_OPENTOFU}_linux_amd64.zip \
    && mv tofu /usr/local/bin \
    && rm tofu_${VERSION_OPENTOFU}_linux_amd64.zip \
    && ln -s /usr/local/bin/tofu /usr/local/bin/terraform \
    && curl -Lo helm.tar.gz https://get.helm.sh/helm-v${VERSION_HELM}-linux-amd64.tar.gz \
    && tar -xvf helm.tar.gz \
    && mv linux-amd64/helm /usr/local/bin \
    && rm -rf linux-amd64 helm.tar.gz \
    && curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=v${VERSION_K3D} bash


ENV CLOUDSDK_COMPONENT_MANAGER_FIXED_SDK_VERSION=${VERSION_GCLOUD_SDK}
# Below includes cleanup to save space after the gcloud install: https://stackoverflow.com/questions/60827959/how-to-stop-gcloud-component-update-from-keeping-a-backup
RUN curl -sSL https://sdk.cloud.google.com | bash \
    && export PATH=$PATH:/usr/local/gcloud/google-cloud-sdk/bin \
    && gcloud components install gke-gcloud-auth-plugin --quiet \
    && gcloud components install alpha --quiet \
    && gcloud components install beta --quiet \
    && rm -rf $(find /usr/local/gcloud/google-cloud-sdk/ -regex ".*/__pycache__") \
    && rm -rf /usr/local/gcloud/google-cloud-sdk/.install/.backup \
    && rm -rf /usr/local/gcloud/google-cloud-sdk/lib/third_party/apis \
    && rm -rf /usr/local/gcloud/google-cloud-sdk/bin/anthoscli \
    && apt update \
    && apt install tmux dnsutils telnet iputils-ping jq certbot -y \
    && apt clean -y
ENV PATH $PATH:/usr/local/gcloud/google-cloud-sdk/bin

RUN apt update \
    && apt install tmux dnsutils telnet iputils-ping jq certbot -y \
    && apt clean -y
RUN sh -c "$(curl --location https://raw.githubusercontent.com/go-task/task/v${VERSION_TASKFILE}/install-task.sh)" -- -d -b /usr/local/bin/
RUN curl -Lo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v${VERSION_KIND}/kind-linux-amd64 \
    && chmod +x /usr/local/bin/kind
RUN wget https://github.com/derailed/k9s/releases/download/v${VERSION_K9S}/k9s_Linux_amd64.tar.gz \
    && tar -xvf k9s_Linux_amd64.tar.gz k9s \
    && mv k9s /usr/local/bin \
    && rm k9s_Linux_amd64.tar.gz
RUN curl -Lo ./terraform-docs.tar.gz https://github.com/terraform-docs/terraform-docs/releases/download/v${VERSION_TERRAFORM_DOCS}/terraform-docs-v${VERSION_TERRAFORM_DOCS}-$(uname)-amd64.tar.gz \ 
    && tar -xzf terraform-docs.tar.gz \
    && chmod +x terraform-docs \ 
    && mv terraform-docs /usr/local/bin \
    && rm terraform-docs.tar.gz
RUN curl -Lo ./kubent-${VERSION_KUBENT}-linux-amd64.tar.gz https://github.com/doitintl/kube-no-trouble/releases/download/${VERSION_KUBENT}/kubent-${VERSION_KUBENT}-linux-amd64.tar.gz \
    && tar -xzf kubent-${VERSION_KUBENT}-linux-amd64.tar.gz \
    && chmod +x kubent \
    && mv kubent /usr/local/bin \
    && rm kubent-${VERSION_KUBENT}-linux-amd64.tar.gz
RUN curl -Lo ./gum_${VERSION_CHARM_GUM}_Linux_x86_64.tar.gz https://github.com/charmbracelet/gum/releases/download/v${VERSION_CHARM_GUM}/gum_${VERSION_CHARM_GUM}_Linux_x86_64.tar.gz \
    && tar --extract --file=gum_${VERSION_CHARM_GUM}_Linux_x86_64.tar.gz gum \
    && chmod +x gum \
    && mv gum /usr/local/bin \
    && rm gum_${VERSION_CHARM_GUM}_Linux_x86_64.tar.gz
RUN curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/v${VERSION_ARGO_CD_CLI}/argocd-linux-amd64 \
    && sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd \
    && rm argocd-linux-amd64

# Install code tunnel so we can run outside of github codespaces easily
RUN wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg \
    && sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg \
    && sudo sh -c 'echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list' \
    && rm -f packages.microsoft.gpg \
    && apt update \
    && apt install code wget gpg apt-transport-https -y \
    && apt clean -y \
    && curl -Lk 'https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64' --output vscode_cli.tar.gz \
    && tar -xf vscode_cli.tar.gz \
    && rm vscode_cli.tar.gz



ARG NONROOT_USER=vscode
RUN echo "#!/bin/sh\n\
    sudoIf() { if [ \"\$(id -u)\" -ne 0 ]; then sudo \"\$@\"; else \"\$@\"; fi }\n\
    SOCKET_GID=\$(stat -c '%g' /var/run/docker.sock) \n\
    if [ \"${SOCKET_GID}\" != '0' ]; then\n\
        if [ \"\$(cat /etc/group | grep :\${SOCKET_GID}:)\" = '' ]; then sudoIf groupadd --gid \${SOCKET_GID} docker-host; fi \n\
        if [ \"\$(id ${NONROOT_USER} | grep -E \"groups=.*(=|,)\${SOCKET_GID}\(\")\" = '' ]; then sudoIf usermod -aG \${SOCKET_GID} ${NONROOT_USER}; fi\n\
    fi\n\
    exec \"\$@\"" > /usr/local/share/docker-init.sh \
    && chmod +x /usr/local/share/docker-init.sh

# VS Code overrides ENTRYPOINT and CMD when executing `docker run` by default.
# Setting the ENTRYPOINT to docker-init.sh will configure non-root access to
# the Docker socket if "overrideCommand": false is set in devcontainer.json.
# The script will also execute CMD if you need to alter startup behaviors.

USER vscode

RUN code --install-extension DavidAnson.vscode-markdownlint --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension dbaeumer.vscode-eslint --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension donjayamanne.python-extension-pack --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension esbenp.prettier-vscode --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension foxundermoon.shell-format --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension GitHub.codespaces --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension GitHub.github-vscode-theme --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension GitHub.vscode-pull-request-github --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension golang.go --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension hashicorp.terraform --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension KevinRose.vsc-python-indent --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension magicstack.MagicPython --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension mohsen1.prettify-json --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension ms-azuretools.vscode-docker --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension ms-python.python --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension ms-python.vscode-pylance --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension ms-vscode.makefile-tools --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension mtxr.sqltools --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension mtxr.sqltools-driver-mysql --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension mtxr.sqltools-driver-pg --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension smoore.yaml-path --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension yzhang.markdown-all-in-one --extensions-dir /home/vscode/.vscode-remote/extensions
RUN mkdir -p /home/vscode/.vscode-server
RUN ln -s /home/vscode/.vscode-remote/extensions /home/vscode/.vscode-server/extensions

ADD ../tools/helm-repositories.yaml /home/vscode/.config/helm/repositories.yaml
RUN mkdir -p /home/vscode/.local/share/helm/plugins \
    && curl -L https://github.com/databus23/helm-diff/releases/download/v${VERSION_HELM_DIFF}/helm-diff-linux-amd64.tgz | tar -C /home/vscode/.local/share/helm/plugins -xzv
RUN git config --global --add --bool push.autoSetupRemote true
USER root
RUN chown -R vscode:vscode /home/vscode
ENTRYPOINT [ "/usr/local/share/docker-init.sh" ]
CMD [ "sleep", "infinity" ]
