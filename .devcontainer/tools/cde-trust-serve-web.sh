#!/usr/bin/env bash
# cde-trust-serve-web — open CDE folders without the "Do you trust the authors…" prompt.
#
# The CDE web UI is served by `code serve-web`, which runs the workbench in the BROWSER.
# In that mode the usual ways to disable Workspace Trust don't work: user settings live in
# the browser (a server-side settings.json is ignored for the application-scoped
# `security.workspace.trust.enabled`), and `product.json` defaults don't reach the browser.
#
# VS Code's SERVER does support a native `--disable-workspace-trust` flag (server-main.js:
# `enableWorkspaceTrust: !args["disable-workspace-trust"]`, which the web workbench turns
# into `disableWorkspaceTrust`, short-circuiting the prompt off). The only catch is that the
# `code serve-web` Rust CLI refuses to forward that flag ("unexpected argument").
#
# serve-web launches the server through a small shell wrapper, `<server>/bin/code-server`,
# which ends with:  "$ROOT/node" ... "$ROOT/out/server-main.js" "$@"
# So we shim that wrapper to append the native flag — a documented flag + a stable launcher
# script, no patching of minified server code. Idempotent and non-fatal.
#
# Called from developer-setup.sh's `dev` before `code serve-web` launches. Deliberately does
# NO network / download: it only shims a server that's already on disk. The serve-web server
# is downloaded lazily on the first browser connection, so on a brand-new container the very
# first connection still prompts once; every `dev` after that shims it and the prompt is gone.

set -u

SW="$HOME/.vscode/cli/serve-web"
SHIM_MARK='cde-trust-serve-web shim'

# Wrap <server>/bin/code-server so the server is always launched with --disable-workspace-trust.
shim_one() {
    local cs="$1" orig="$1.orig" tmp
    [ -f "$cs" ] || return 1
    grep -q "$SHIM_MARK" "$cs" 2>/dev/null && return 0     # already shimmed
    [ -f "$orig" ] || cp -p "$cs" "$orig"                  # preserve the real launcher once
    tmp="$cs.tmp.$$"
    cat > "$tmp" <<'SH'
#!/usr/bin/env sh
# cde-trust-serve-web shim — pass VS Code's native --disable-workspace-trust flag to the
# server (code serve-web won't forward it) so serve-web opens folders without the trust prompt.
exec "$(dirname "$0")/code-server.orig" "$@" --disable-workspace-trust
SH
    chmod +x "$tmp"
    mv "$tmp" "$cs"
}

changed=0
for cs in "$SW"/*/bin/code-server; do
    case "$cs" in *".staging/"*) continue ;; esac   # skip the transient download dir
    [ -f "$cs" ] || continue                          # no server downloaded yet -> nothing to do
    grep -q "$SHIM_MARK" "$cs" 2>/dev/null && continue
    if shim_one "$cs"; then
        echo "cde-trust-serve-web: shimmed $cs with --disable-workspace-trust"
        changed=1
    fi
done

if [ "$changed" -eq 0 ]; then
    echo "cde-trust-serve-web: no change (already shimmed, or server not downloaded yet)"
fi
exit 0
