# AGENTS.md

The GlueOps codespace: the devcontainer image (`ghcr.io/glueops/codespaces`) with the tools to run the GlueOps
platform, and the VM setup that runs it as a cloud development environment (CDE) created from Slack.

## Repo map

- `.devcontainer/Dockerfile`: the codespace image. `.devcontainer/tools/` holds the tools installed into it
  (`cde-boot`, `cde-init`, `cde-trust-serve-web`, `captain_utils`, `gluekube_ssh`, ...).
- `developer-setup.sh`: VM setup, run at golden-image build (Packer) and by the break-glass `curl setup.glueops.dev |
  bash`. It embeds the VM's scripts and systemd units as heredocs, so it must stay a single self-contained file:
  `codespace-ensure`, `codespace-tunnel`, `dev`, `/usr/local/lib/codespace/common.sh`, and the
  `codespace-ensure.{service,timer}` and `codespace-tunnel.service` units. README "The codespace VM" explains them.
- `qemu.pkr.hcl`, `os-setup-start.sh`, `os-setup-finish.sh`: the Packer VM image.
- `hack/`: test runners (`hack/test.sh` runs them all) and `hack/vm-recovery-test.sh` (manual, against a real VM).
- `tests/vm/`: behaviour tests and stubs for the VM scripts. App tests live under `.devcontainer/tests/<app>/`.

## Build and test (in Docker)

- `hack/test-codespace-vm.sh`: the VM scripts and units, inside a pinned debian:13 container (needs docker).
- `hack/test-captain-utils.sh`, `hack/test-gluekube-ssh.sh`: the image's tools.
- `hack/test.sh`: all of the above (`CODESPACE_VM_TEST_DOCKER=1` to include the VM suite).
- Each suite has its own workflow under `.github/workflows/` with path triggers.

## Rules

- Each embedded file in `developer-setup.sh` has its own quoted heredoc delimiter (`<<'CODESPACE_..._EOF'`), never
  `<<-`, and the test runner extracts files by those delimiters. Nothing it runs at setup time may read stdin
  (`curl | bash` feeds the script on stdin).
- Units that run after cloud-final must be `WantedBy=cloud-init.target`, never `multi-user.target`: cloud-final is
  ordered after multi-user.target, and the cycle makes systemd drop the job at boot. The VM test suite checks this.
- The connection token (`/etc/glueops/cde_token`) never goes on a command line, into the environment or into logs.
  `code serve-web` prints it on stdout, so its stdout is discarded.
- `packer-qemu.yml` is triggered by `workflow_run`, so it always runs the default branch's copy: a tag builds its own
  `qemu.pkr.hcl` with `main`'s workflow (runner, env, `PKR_VAR_*`). A pre-release can't test edits to that workflow,
  and `qemu.pkr.hcl`'s defaults must work under `main`'s.
- Conventional Commits, release-please friendly.

## Decisions

Settled; reviewers shouldn't re-raise these.

- VM and boot changes may be breaking. Existing VMs are not migrated: people create a new codespace from Slack.
- No memory cap on the container and no swap file. The OOM kills come from other workloads; recovery handles them.
- The editor runs as the container's main process, supervised by Docker's restart policy plus the per-minute
  `codespace-ensure`. A crash of that process also ends shells and jobs inside the container. That's accepted.
- No automatic recreate of a container that won't start; `dev status` points to `dev reset`.
- The home and `/nix` volumes keep the home contents from the image tag they were first created with, even if a newer
  tag later runs on the same VM. Upgrading means a new VM. Volumes are not a backup.
- The browser editor's VS Code server is pinned (`serve-web --commit-id`) to the one baked into the image: a VM gets no
  VS Code updates in place, including security releases, until a new VM. In exchange there's no ~700 MB download on a
  browser connect and the workspace-trust shim always applies.
- VS Code is one version, `ARG VERSION_VSCODE` in the Dockerfile (code package, CLI, and the baked server via the CLI's
  commit). New images get a newer VS Code only when Renovate bumps it; `renovate.json` exempts it from the org's 30-day
  wait so security releases reach new images quickly.
- The browser editor runs with `--disable-telemetry`. `code tunnel` has no such flag; its users' own VS Code settings apply.
- Credentials kept in the home volume survive a container recreate. `dev reset` removes them.
- The sish tunnel keeps `StrictHostKeyChecking=no` with `UserKnownHostsFile=/dev/null`: sish host keys may change.
- serve-web listens on 127.0.0.1 only; nobody uses :8000 on the tailnet IP.
- A code-tunnel login that's waiting is shown by `dev status` and `docker logs`, with no more than that.
- `dev` keeps the `dev` tmux session (windows `logs` and `shell`) for people who log in. In browser-editor mode the
  `logs` window follows the unit journals; the container's own output is a `docker logs codespace` hint in `dev status`.
- Free disk space in `dev status` is information only; it doesn't make the codespace unhealthy.
- Accepted edge cases, not fixed:
  - `dev reset` doesn't wait for an ensure run already in progress.
  - `dev reset` with no terminal just refuses to run; there's no `--yes` flag.
  - A missing `.pub` beside an existing tunnel key isn't repaired.
  - A failed `cde-boot` is retried only when the container is next created or started, not after Docker's own restarts.
  - A container in `restarting` is treated as running.
  - Nothing guards against a broken heredoc end marker beyond the extraction check.
  - The tmux session name isn't protected against a session called e.g. `devbox`.
  - Two `dev` runs creating the session at the same moment isn't handled.
