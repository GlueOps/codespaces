# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.233.0/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
#https://mcr.microsoft.com/v2/devcontainers/base/tags/list
#https://github.com/devcontainers/images/tree/main/src/base-ubuntu
FROM mcr.microsoft.com/vscode/devcontainers/base:2-ubuntu-22.04@sha256:81380e4c9c14e8a629ff39029639e4b7893e67400246fa7782a0fe7dc193a02a

# [Optional] Uncomment this section to install additional OS packages.
# RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
#     && apt-get -y install --no-install-recommends <your-package-list-here>


# renovate: datasource=github-tags depName=kubernetes/kubectl
ARG VERSION_KUBECTL=1.34.6
# renovate: datasource=github-tags depName=opentofu/opentofu
ARG VERSION_OPENTOFU=1.11.8
# renovate: datasource=github-tags depName=helm/helm
ARG VERSION_HELM=3.20.2
# renovate: datasource=github-tags depName=kubernetes-sigs/kind
ARG VERSION_KIND=0.32.0
# renovate: datasource=github-tags depName=derailed/k9s
ARG VERSION_K9S=0.51.0
# renovate: datasource=github-tags depName=terraform-docs/terraform-docs
ARG VERSION_TERRAFORM_DOCS=0.24.0
# renovate: datasource=github-tags depName=doitintl/kube-no-trouble
ARG VERSION_KUBENT=0.7.3
# renovate: datasource=github-tags depName=databus23/helm-diff
ARG VERSION_HELM_DIFF=3.15.8
# renovate: datasource=github-tags depName=charmbracelet/gum
ARG VERSION_CHARM_GUM=0.17.0
# renovate: datasource=github-tags depName=argoproj/argo-cd
ARG VERSION_ARGO_CD_CLI=3.3.11
# renovate: datasource=github-tags depName=k3d-io/k3d
ARG VERSION_K3D=5.9.0
# renovate: datasource=github-tags depName=hashicorp/packer
ARG VERSION_HASHICORP_PACKER=1.15.4
# renovate: datasource=github-tags depName=kubernetes-sigs/krew
ARG VERSION_KREW=0.5.0
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG VERSION_CLAUDE_CODE=2.1.197
# renovate: datasource=github-tags depName=cloudflare/cloudflared
ARG VERSION_CLOUDFLARED=2026.6.1

# https://developer.hashicorp.com/vault/docs/commands#vault_skip_verify
# https://github.com/GlueOps/terraform-module-kubernetes-hashicorp-vault-configuration/wiki
ENV VAULT_SKIP_VERIFY true
ENV CLOUDSDK_INSTALL_DIR /usr/local/gcloud/
ENV GIT_EDITOR vi
# enable team of agents: https://code.claude.com/docs/en/agent-teams
ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

COPY tools/ /etc/tools/

# Install tools to /usr/local/bin
RUN for file in /etc/tools/*; do \
        if [ -f "$file" ]; then \
            new_name=$(basename "$file" .sh); \
            cp "$file" "/usr/local/bin/$new_name"; \
            chmod +x "/usr/local/bin/$new_name"; \
            echo "Copied and made executable: $new_name"; \
        fi; \
    done && \
    rm -rf /etc/tools
    
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


RUN apt update \
    && apt install tmux dnsutils telnet iputils-ping jq certbot nethogs nload vim socat -y \
    && apt clean -y
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
    && tar -xzvf gum_${VERSION_CHARM_GUM}_Linux_x86_64.tar.gz && mv gum_*/gum gum \
    && chmod +x gum \
    && mv gum /usr/local/bin \
    && rm gum_${VERSION_CHARM_GUM}_Linux_x86_64.tar.gz \
    && rm -rf gum_${VERSION_CHARM_GUM}_Linux_x86_64
RUN curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/v${VERSION_ARGO_CD_CLI}/argocd-linux-amd64 \
    && sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd \
    && rm argocd-linux-amd64
RUN wget "https://releases.hashicorp.com/packer/${VERSION_HASHICORP_PACKER}/packer_${VERSION_HASHICORP_PACKER}_linux_amd64.zip" \
    && unzip packer_${VERSION_HASHICORP_PACKER}_linux_amd64.zip \
    && mv packer /usr/local/bin \
    && rm packer_${VERSION_HASHICORP_PACKER}_linux_amd64.zip \
    && rm LICENSE.txt

RUN wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq &&\
    sudo chmod +x /usr/local/bin/yq

# dpkg --print-architecture (amd64/arm64) matches cloudflared's asset naming, so this works for a future multi-arch build
RUN curl -Lo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/download/${VERSION_CLOUDFLARED}/cloudflared-linux-$(dpkg --print-architecture) \
    && chmod +x /usr/local/bin/cloudflared

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

#AWS Debian has a user of admin that uses the UID of 1000. THis is to try and fix that. We are also using UID of 1337 on the system/host level here: https://github.com/GlueOps/development-only-utilities/blob/main/tools/developer-setup/linux-setup.sh#L8
RUN usermod --uid 1337 vscode --shell /bin/zsh

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

RUN code --install-extension MS-vsliveshare.vsliveshare --extensions-dir /home/vscode/.vscode-remote/extensions
RUN code --install-extension GitHub.codespaces --extensions-dir /home/vscode/.vscode-remote/extensions

# Install krew (kubectl plugin manager) into $HOME/.krew, then install the oidc-login plugin
RUN cd /tmp \
    && curl -fsSLO https://github.com/kubernetes-sigs/krew/releases/download/v${VERSION_KREW}/krew-linux_amd64.tar.gz \
    && tar zxf krew-linux_amd64.tar.gz \
    && ./krew-linux_amd64 install krew \
    && rm -f krew-linux_amd64 krew-linux_amd64.tar.gz LICENSE \
    && export PATH="$HOME/.krew/bin:$PATH" \
    && kubectl krew install oidc-login \
    && kubectl krew version \
    && kubectl oidc-login --help > /dev/null

# Make $HOME/.krew/bin available to every process (including non-interactive shells and kubeconfig exec: plugins)
ENV PATH=/home/vscode/.krew/bin:$PATH

RUN curl -L https://nixos.org/nix/install | bash -s -- --no-daemon
# 0.14.0 came out a couple weeks ago and it appears to be problematic. So pinning and manually upgrading seems like a good option
ENV DEVBOX_USE_VERSION=0.13.0
RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f

# Install Claude Code via the native (nodeless) installer into ~/.local/bin, which is already on PATH.
# npm isn't available at image-build time (node comes from a devcontainer feature applied afterwards).
RUN curl -fsSL https://claude.ai/install.sh | bash -s ${VERSION_CLAUDE_CODE}


RUN mkdir -p /home/vscode/.vscode-server
RUN ln -s /home/vscode/.vscode-remote/extensions /home/vscode/.vscode-server/extensions

ADD ../misc-configs/helm-repositories.yaml /home/vscode/.config/helm/repositories.yaml
RUN mkdir -p /home/vscode/.local/share/helm/plugins \
    && curl -L https://github.com/databus23/helm-diff/releases/download/v${VERSION_HELM_DIFF}/helm-diff-linux-amd64.tgz | tar -C /home/vscode/.local/share/helm/plugins -xzv
RUN git config --global --add --bool push.autoSetupRemote true

RUN curl -sL https://aka.ms/DevTunnelCliInstall | bash

RUN curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
  sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
  sudo tee /etc/apt/sources.list.d/1password.list && \
  sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/ && \
  curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | \
  sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol && \
  sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22 && \
  curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
  sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg && \
  sudo apt update && sudo apt install 1password-cli

# Disable VS Code Workspace Trust so folders (e.g. /workspaces/glueops) always open
# trusted -- no "Do you trust the authors..." prompt blocking terminals/tasks on launch.
# These are ephemeral CDEs that only ever open the user's own GlueOps repos.
RUN mkdir -p /home/vscode/.vscode-server/data/Machine/ && echo '{"workbench.colorTheme": "VS Code Dark", "security.workspace.trust.enabled": false}' > /home/vscode/.vscode-server/data/Machine/settings.json

# The apt `code` package installs the desktop (Electron) binary at /usr/bin/code.
# In these headless serve-web/tunnel sessions there is no X display, so running
# `code <file>` in the terminal crashes ("Missing X server or $DISPLAY").
# Drop a wrapper on $HOME/.local/bin (first on the interactive PATH, see .zshrc/.bashrc
# below) that forwards to the serve-web/remote-cli shim, which opens files in a running
# VS Code window over its $VSCODE_IPC_HOOK_CLI socket. The wrapper picks the newest shim
# so it survives VS Code updates, and routes to the newest live window socket so it keeps
# working in long-lived shells (e.g. tmux) whose captured socket has gone stale (see the
# inline comments). Only affects interactive shells; build-time `code --install-extension`
# above still resolves to /usr/bin/code.
RUN mkdir -p /home/vscode/.local/bin \
    && printf '%s\n' \
        '#!/usr/bin/env sh' \
        '# Route `code` to the VS Code serve-web/remote CLI shim instead of the GUI desktop' \
        '# binary (/usr/bin/code), which has no display in this container and crashes.' \
        '' \
        '# 0. tunnel/serve-web are full-CLI subcommands the remote-cli shim does not implement' \
        '#    (it would treat "tunnel" as a filename to open) and they need no window socket.' \
        '#    Hand them to the real /usr/bin/code, which dispatches them to its bundled CLI and' \
        '#    runs fine headless. Use the absolute path -- calling `code` here would recurse' \
        '#    into this wrapper.' \
        'case "$1" in' \
        '  tunnel|serve-web) exec /usr/bin/code "$@" ;;' \
        'esac' \
        '' \
        '# 1. Locate the remote CLI shim. There is one per installed VS Code build and the' \
        '#    path embeds a build hash, so pick the newest to survive VS Code updates. The' \
        '#    -x check turns a found-but-not-executable match into the friendly error below' \
        '#    instead of an opaque `exec: Permission denied`.' \
        'shim=$(ls -t "$HOME"/.vscode/cli/serve-web/*/bin/remote-cli/code \' \
        '              "$HOME"/.vscode-server/bin/*/bin/remote-cli/code \' \
        '              "$HOME"/.vscode-server/cli/servers/*/server/bin/remote-cli/code \' \
        '              2>/dev/null | head -n1)' \
        'if [ -z "$shim" ] || [ ! -x "$shim" ]; then' \
        '  echo "code: no usable VS Code remote CLI shim found; is a serve-web/remote session running?" >&2' \
        '  exit 1' \
        'fi' \
        '' \
        '# 2. Choose the IPC socket of the window to open files in. $VSCODE_IPC_HOOK_CLI is' \
        '#    captured when the shell starts, so a long-lived shell (e.g. a tmux server that' \
        '#    outlives a VS Code reconnect) keeps pointing at an OLD window. That old socket' \
        '#    often still accepts connections, so files silently open in a window you can no' \
        '#    longer see. VS Code creates one socket per window/connection under /tmp, so the' \
        '#    newest is your current window: prefer the newest socket that still accepts a' \
        '#    connection, falling back to older ones. If none is reachable, keep whatever the' \
        '#    environment provided so socket-less subcommands (code --version, etc.) still work.' \
        '#    LIMITATION: "newest socket" is the current window only with a single window/tab' \
        '#    open. With multiple windows, or after an extension-host reload, files may open in' \
        '#    another window -- serve-web exposes no API to target a specific window, so this is' \
        '#    the best heuristic available.' \
        'ipc_live() {' \
        '  [ -S "$1" ] || return 1' \
        '  # Best-effort connect probe to skip sockets whose window has gone away. socat is' \
        '  # optional here: if it is not installed, treat an existing socket as usable. The' \
        '  # timeout bounds the connect so a pathological socket can never wedge `code`.' \
        '  command -v socat >/dev/null 2>&1 || return 0' \
        '  timeout 2 socat -u OPEN:/dev/null UNIX-CONNECT:"$1" >/dev/null 2>&1' \
        '}' \
        'for sock in $(ls -t /tmp/vscode-ipc-*.sock 2>/dev/null); do' \
        '  if ipc_live "$sock"; then' \
        '    VSCODE_IPC_HOOK_CLI="$sock"' \
        '    export VSCODE_IPC_HOOK_CLI' \
        '    break' \
        '  fi' \
        'done' \
        '' \
        '# 3. Hand off to the shim, preserving every argument and its exit status.' \
        'exec "$shim" "$@"' \
        > /home/vscode/.local/bin/code \
    && chmod +x /home/vscode/.local/bin/code

# Add backup warning to .zshrc for vscode user
RUN echo '\n# === Backup & Git Reminder ===' | tee -a /home/vscode/.zshrc && \
    echo 'echo -e "\e[1;31m⚠️  WARNING: No backups are configured. You are responsible for any data loss.\e[0m"' | tee -a /home/vscode/.zshrc && \
    echo 'echo -e "\e[1;33m💡 Tip: Use '\''git commit'\'' and '\''git push'\'' regularly to avoid losing your work.\e[0m"' | tee -a /home/vscode/.zshrc && \
    echo '# =============================' | tee -a /home/vscode/.zshrc && \
    echo 'export PATH="$HOME/.local/bin:$HOME/.krew/bin:$PATH"' | tee -a /home/vscode/.zshrc /home/vscode/.bashrc && \
    chown vscode:vscode /home/vscode/.zshrc /home/vscode/.bashrc

USER root
RUN mkdir -p /home/vscode/.kube && chmod 0700 /home/vscode/.kube
RUN chown -R vscode:vscode /home/vscode
ENTRYPOINT [ "/usr/local/share/docker-init.sh" ]
CMD [ "sleep", "infinity" ]
