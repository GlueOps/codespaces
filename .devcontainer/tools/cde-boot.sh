#!/usr/bin/env bash
# cde-boot — run the CDE setup once per container.
#
# Invoked by developer-setup.sh's `dev` at container startup. Runs whatever CDE_SETUP_SCRIPT
# contains (from the container env, populated from /etc/glueops/codespace.env):
#   - a plain command / tool name (the usual default value is `cde-init`)  -> run as-is
#   - a value prefixed with `base64:`                                       -> decode, then run
#   - empty / unset                                                         -> do nothing
# Idempotent: a sentinel file makes it a no-op on reconnect; CDE_INIT_FORCE=1 forces a re-run.
# Non-fatal by design — a failing setup script must never block the CDE from coming up.

SENTINEL="$HOME/.cde-init-done"
[ -f "$SENTINEL" ] && [ -z "${CDE_INIT_FORCE:-}" ] && exit 0

script="${CDE_SETUP_SCRIPT:-}"
# Complex/multi-line scripts are base64-encoded (the Slack bot sanitiser flattens newlines,
# so `tr -d` strips any injected whitespace before decoding).
case "$script" in
    base64:*) script="$(printf '%s' "${script#base64:}" | tr -d '[:space:]' | base64 -d 2>/dev/null)" ;;
esac

if [ -n "$script" ]; then
    bash -lc "$script" || echo "cde-boot: setup script exited non-zero (continuing)"
fi

touch "$SENTINEL"
