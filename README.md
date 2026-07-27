# codespaces

## Description: 

This repo contains all the environmental tools/dependencies to deploy the entire glueops platform. Tools include but are not limited to: terraform, helm, kubectl, devbox/nix, etc. We primarily use this repository in all of our codespaces as well as github actions. Ref: https://github.com/GlueOps/glueops/blob/%F0%9F%9A%80%F0%9F%92%8E%F0%9F%99%8C%F0%9F%9A%80/.devcontainer/devcontainer.json#L5

## DevBox

Since we have devbox installed any packages/tools that aren't installed (e.g. python) can easily be fetched from https://www.nixhub.io/

Here is a quick getting started with devbox: https://jetify.com/docs/devbox/quickstart/#create-a-development-environment

```bash
devbox init
devbox add python@3.10
devbox shell
python --version
```

## CDE bootstrap: `cde-init` / `CDE_SETUP_SCRIPT`

When a codespace container starts, `dev` runs a one-time bootstrap (`cde-boot`) driven by the `CDE_SETUP_SCRIPT` environment variable (supplied by the Slack bot via `/etc/glueops/codespace.env`). The value selects what runs:

- **unset / empty** (the default — the Slack bot leaves it commented out) — runs **`cde-init`**: authenticates GitHub from `GITHUB_TOKEN` (non-interactive; runs `gh auth setup-git` so `git`/private-repo clones work, and sets your git identity), clones `GLUEOPS_CDE_CLONE_REPO` into `/workspaces/glueops/<repo>` (public repos need no token), and seeds `gluekube_ssh` (AutoGlue) `prod`/`nonprod` profiles from `GLUEKUBE_SSH_AUTOGLUE_{PROD,NONPROD}_{URL,TOKEN}` — a profile is seeded only when **both** its URL and token are set.
- **a command** — e.g. `curl setup.example.com | zsh` runs instead of `cde-init`.
- **`base64:<encoded>`** — a base64-encoded script, for complex/multi-line setup (`<your script> | base64 -w0`). A decode failure is refused (never runs a partial script).
- **`true`** (or any no-op) — skip setup entirely.

Every step is best-effort and non-fatal; unconfigured inputs are skipped. It runs once per container: the sentinel `~/.cde-init-done` is written **only when setup exits 0**, so a hard failure (or a bad `base64:` value) is retried on the next boot rather than silently marked done; output is captured to `~/.cde-init.log`. Set `CDE_INIT_FORCE=1`, or just run `cde-init` / `cde-boot` again, to re-run. The tools live in `.devcontainer/tools/` (`cde-init.sh`, `cde-boot.sh`) and are installed to `/usr/local/bin` by the image build.

Because the default GitHub auth is token-based, running `yolo` afterward is a smooth no-op (it detects the existing auth and skips the interactive browser login).

# Releasing:
- Please stick to semver standards when dropping a new tag.
- Once you publish a release a new image will be built and uploaded to GHCR.io: https://github.com/GlueOps/codespaces/pkgs/container/codespaces
- Please tag the release as a `pre-release` this will prevent it from being pulled by production users whie it's still building. Once the AWS/QMEU/etc. pipelines have finished, and after you have tested the `pre-release` go ahead and update the release to `latest release`. [Here is a quick video on promoting from pre-release to the latest release](https://github.com/user-attachments/assets/e94b4b34-9aa7-4440-a3d7-8c49cf32f2ea)



**Note:** Due to the connection between the packer workflows and the Docker build/publish workflow, it's not possible to cut a release from any branch other than `main`. Some limitations in GitHub prevent the actions checkout step in the packer workflows from accurately determining the parent commit SHA, which defaults to `main`. Therefore, if you're testing changes outside of the Dockerfile, this method may not provide accurate results. One potential solution is to combine all the workflows, but this would result in a runtime of an hour or more.


# QA / Testing:

To test a `pre-release` you will first to do the following:
1) Make sure a nonprod/stage provisioner API functioning is working and has a node for you to test with.
2) In the nonprod slack channel for the developer workspaces (e.g. `#testing-developer-workspaces`) run `!vm` and you should see the `pre-release` tag.
3) Select the `pre-release` tag and login to the VM as normal.
4) Once you change to the `vscode` user, run `export ENVIRONMENT=nonprod` and then run `dev` as usual
5) You should now see the `pre-release` tag you created earlier as part of the release process, select it and preform your tests.


# Local Dev / Running packer locally:

It's best to just reference the github workflows under `.github/workflows` the packer workflows for each respective cloud start with `packer-*`. For each respective cloud you will notice env variables are being passed into a github action step. To do this locally, you will need to create credentials for the respective cloud and then `export` the applicable environment variables before running the `packer build` command.

### Break Glass Setup

If you are having issues spinning up a VM using our automation, just create a VM/Server with a provider of your choice and run these commands:

```bash
# Optional, export GLUEOPS_CODESPACES_CONTAINER_TAG if you want to specify a specific version. Otherwise the latest release will be grabbed/pulled. Note: if the latest release was just published then it may not be available for download yet and the bootstrap may fail
# export GLUEOPS_CODESPACES_CONTAINER_TAG=v0.129.0 #update tag to latest version found here: https://github.com/GlueOps/codespaces/releases
curl -sL setup.glueops.dev | bash
sudo tailscale up --ssh
```

_Note:_ as of April 2025 we have been using Debian 12 as our base Operating System. It's possible Debian 13 or newer work but we haven't tested it yet.

