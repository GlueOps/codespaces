# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.233.0/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
ARG VARIANT="jammy"
FROM mcr.microsoft.com/vscode/devcontainers/base:0-${VARIANT}

# [Optional] Uncomment this section to install additional OS packages.
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#     && apt-get -y install --no-install-recommends <your-package-list-here>


ENV CLOUDSDK_INSTALL_DIR /usr/local/gcloud/
ADD ../glueops-fetch-repos /usr/bin/glueops-repo-fetch
RUN chmod +x /usr/bin/glueops-repo-fetch
RUN curl -sSL https://sdk.cloud.google.com | bash
ENV PATH $PATH:/usr/local/gcloud/google-cloud-sdk/bin
RUN gcloud components install gke-gcloud-auth-plugin --quiet
RUN gcloud components install alpha --quiet
RUN gcloud components install beta --quiet
RUN sh -c "$(curl --location https://raw.githubusercontent.com/go-task/task/v3.19.0/install-task.sh)" -- -d -b /usr/local/bin/
#RUN curl https://stedolan.github.io/jq/download/linux64/jq > /usr/local/bin/jq && sudo chmod +x /usr/local/bin/jq
RUN apt update && apt install tmux dnsutils telnet iputils-ping jq certbot -y && apt clean -y
RUN curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/v2.5.2/argocd-linux-amd64
RUN chmod +x /usr/local/bin/argocd
RUN curl -Lo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.17.0/kind-linux-amd64
RUN chmod +x /usr/local/bin/kind
RUN wget https://github.com/derailed/k9s/releases/download/v0.26.7/k9s_Linux_x86_64.tar.gz
RUN tar -xvf k9s_Linux_x86_64.tar.gz k9s
RUN mv k9s /usr/local/bin
RUN rm k9s_Linux_x86_64.tar.gz

ARG NONROOT_USER=vscode
RUN git config --global --add --bool push.autoSetupRemote true

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
ENTRYPOINT [ "/usr/local/share/docker-init.sh" ]
CMD [ "sleep", "infinity" ]
