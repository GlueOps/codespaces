# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.233.0/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
ARG VARIANT="jammy"
FROM mcr.microsoft.com/vscode/devcontainers/base:0-${VARIANT}

# [Optional] Uncomment this section to install additional OS packages.
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#     && apt-get -y install --no-install-recommends <your-package-list-here>

# https://developer.hashicorp.com/vault/docs/commands#vault_skip_verify
# https://github.com/GlueOps/terraform-module-kubernetes-hashicorp-vault-configuration/wiki

ARG VERSION_KUBECTL=1.26.3
ARG VERSION_TERRAFORM=1.4.5
ARG VERSION_HELM=3.11.3
ARG VERSION_GCLOUD_SDK=427.0.0
ARG VERSION_TASKFILE=3.24.0
ARG VERSION_KIND=1.18.0
ARG VERSION_K9S=0.27.3
ARG VERSION_TERRAFORM_DOCS=0.16.0
ARG VERSION_KUBENT=0.7.0
ARG VERSION_HELM_DIFF=3.6.0

ENV VAULT_SKIP_VERIFY true
ENV CLOUDSDK_INSTALL_DIR /usr/local/gcloud/
ADD ../tools/glueops-fetch-repos /usr/bin/glueops-repo-fetch
ADD ../tools/run-gha /usr/bin/run-gha
RUN chmod +x \
  /usr/bin/glueops-repo-fetch \
  /usr/bin/run-gha
ADD ../tools/helm-repositories.yaml /home/vscode/.config/helm/repositories.yaml
RUN curl -Lo /usr/local/bin/kubectl https://dl.k8s.io/release/v${VERSION_KUBECTL}/bin/linux/amd64/kubectl \
    && curl -Lo terraform_${VERSION_TERRAFORM}_linux_amd64.zip https://releases.hashicorp.com/terraform/${VERSION_TERRAFORM}/terraform_${VERSION_TERRAFORM}_linux_amd64.zip \
    && unzip terraform_${VERSION_TERRAFORM}_linux_amd64.zip \
    && mv terraform /usr/local/bin \
    && rm terraform_${VERSION_TERRAFORM}_linux_amd64.zip \
    && curl -Lo helm.tar.gz https://get.helm.sh/helm-v${VERSION_HELM}-linux-amd64.tar.gz \
    && tar -xvf helm.tar.gz \
    && mv linux-amd64/helm /usr/local/bin \
    && rm -rf linux-amd64 helm.tar.gz

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
RUN sh -c "$(curl --location https://raw.githubusercontent.com/go-task/task/v${VERSION_TASKFILE}/install-task.sh)" -- -d -b /usr/local/bin/
#RUN curl https://stedolan.github.io/jq/download/linux64/jq > /usr/local/bin/jq && sudo chmod +x /usr/local/bin/jq
ENV PATH $PATH:/usr/local/gcloud/google-cloud-sdk/bin
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
RUN mkdir -p /home/vscode/.local/share/helm/plugins \
    && curl -L https://github.com/databus23/helm-diff/releases/download/v${VERSION_HELM_DIFF}/helm-diff-linux-amd64.tgz | tar -C /home/vscode/.local/share/helm/plugins -xzv
RUN git config --global --add --bool push.autoSetupRemote true
USER root
ENTRYPOINT [ "/usr/local/share/docker-init.sh" ]
CMD [ "sleep", "infinity" ]
