#!/usr/bin/env bash
# cde-boot — run the CDE setup once per container.
#
# Invoked by developer-setup.sh's `dev` at container startup. Runs whatever CDE_SETUP_SCRIPT
# contains (from the container env, populated from /etc/glueops/codespace.env):
#   - unset / empty                                                         -> run cde-init (default)
#   - a plain command / tool name (e.g. `cde-init`)                         -> run as-is
#   - a value prefixed with `base64:`                                       -> decode, then run
#   - `true` (or any no-op)                                                 -> skip setup
# Idempotent: a sentinel file makes it a no-op on reconnect; CDE_INIT_FORCE=1 forces a re-run.
# Non-fatal by design — a failing setup script must never block the CDE from coming up.

SENTINEL="$HOME/.cde-init-done"
LOG="$HOME/.cde-init.log"
[ -f "$SENTINEL" ] && [ -z "${CDE_INIT_FORCE:-}" ] && exit 0

# Unset/empty -> run the default bootstrap. The Slack bot leaves CDE_SETUP_SCRIPT unset by
# default (its pre-seed line is commented out), so the happy path is cde-init. To skip setup
# entirely, a developer sets CDE_SETUP_SCRIPT=true.
script="${CDE_SETUP_SCRIPT:-cde-init}"

# Complex/multi-line scripts are base64-encoded (the Slack bot sanitiser flattens newlines,
# so `tr -d` strips any injected whitespace before decoding). If the decode fails or yields
# nothing (corrupt/truncated value), refuse to run a partial script and leave the sentinel
# alone so it's retried on the next boot — never execute half a command.
case "$script" in
    base64:*)
        if ! decoded="$(printf '%s' "${script#base64:}" | tr -d '[:space:]' | base64 -d 2>/dev/null)" || [ -z "$decoded" ]; then
            echo "cde-boot: base64 decode failed; refusing to run (will retry next boot)" | tee -a "$LOG"
            exit 0
        fi
        script="$decoded"
        ;;
esac

# Run the setup, tee output to the log, and mark done ONLY on success — a hard failure is
# retried on the next boot instead of being silently marked complete.
bash -lc "$script" 2>&1 | tee -a "$LOG"
status=${PIPESTATUS[0]}
if [ "$status" -eq 0 ]; then
    touch "$SENTINEL"
else
    echo "cde-boot: setup exited $status; will retry next boot" | tee -a "$LOG"
fi
