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
# `code serve-web` downloads the server LAZILY on the first browser connection, not at
# startup — so to have the shim in place before that first connection (and avoid a one-time
# prompt), we front-load the download here: briefly start serve-web on a local port and hit
# it once (this is the same download that would happen on first connect, just moved earlier).
#
# WHERE THIS RUNS: (1) at IMAGE BUILD — .devcontainer/Dockerfile runs this and then asserts
# the shim landed, so the build fails if it didn't; (2) at RUNTIME — developer-setup.sh's
# `dev` calls it before `code serve-web` (a no-op when the baked server is already shimmed;
# re-shims if a VS Code update pulled a new server).
#
# ─────────────────────────────────────────────────────────────────────────────────────────
# IF THIS BREAKS (trust prompt returns, OR the Dockerfile build assertion fails): it almost
# always means a VS Code version bump changed something below. Re-check these three facts
# against the downloaded server at ~/.vscode/cli/serve-web/<hash>/ and update the matching
# piece (or re-derive from the workbench source):
#
#   1. LAUNCHER SHAPE — we shim `bin/code-server`, which must still be a shell wrapper ending
#      in `"$ROOT/node" ... "$ROOT/out/server-main.js" "$@"`.
#        tail -3 ~/.vscode/cli/serve-web/*/bin/code-server.orig
#      If the path/shape changed, update SW / the glob / the shim in this file.
#
#   2. THE FLAG STILL WORKS — server-main.js must still set enableWorkspaceTrust from the arg:
#        grep -o 'enableWorkspaceTrust[^,]*' ~/.vscode/cli/serve-web/*/out/server-main.js
#      Expect: enableWorkspaceTrust:!...args["disable-workspace-trust"]
#
#   3. THE WORKBENCH STILL GATES ON IT — web build must still short-circuit:
#      isWorkspaceTrustEnabled = disableWorkspaceTrust ? false : <config>, and
#      disableWorkspaceTrust   = !options.enableWorkspaceTrust
#        f=~/.vscode/cli/serve-web/*/out/vs/workbench/workbench.web.main.internal.js
#        grep -o 'isWorkspaceTrustEnabled(){[^}]*}' $f
#        grep -o 'get disableWorkspaceTrust(){[^}]*}' $f
#      If (2)/(3) changed, the whole flag approach may no longer apply — re-derive the lever.
#
# Ruled-out alternatives (don't waste time retrying these — verified not to work for
# serve-web web mode): settings.json (User or Machine), product.json configurationDefaults,
# and passing --disable-workspace-trust to `code serve-web` (the Rust CLI rejects it).
# ─────────────────────────────────────────────────────────────────────────────────────────

set -u

SW="$HOME/.vscode/cli/serve-web"
SHIM_MARK='cde-trust-serve-web shim'

# Everything here assumes HOME=/home/vscode — where the image bakes the server and where
# serve-web downloads it. If the container runs as a uid without that home (the image is
# built for uid 1337 / user `vscode`), the baked+shimmed server isn't found and the trust
# prompt silently returns. Warn loudly so that's easy to spot rather than a mystery.
[ "$HOME" = "/home/vscode" ] || \
    echo "cde-trust-serve-web: WARNING: HOME=$HOME (expected /home/vscode); shim may not take effect" >&2

# Remove any temp file we might leave behind if interrupted mid-write (PID-scoped).
trap 'rm -f "$SW"/*/bin/code-server.tmp."$$" 2>/dev/null || true' EXIT

# True when a fully-extracted server wrapper exists (ignore the transient "<hash>.staging" dir).
server_present() {
    local f
    for f in "$SW"/*/bin/code-server; do
        case "$f" in *".staging/"*) continue ;; esac
        [ -f "$f" ] && return 0
    done
    return 1
}

# Wrap <server>/bin/code-server so the server is always launched with --disable-workspace-trust.
shim_one() {
    local cs="$1" orig="$1.orig" tmp
    [ -f "$cs" ] || return 1
    grep -qF "$SHIM_MARK" "$cs" 2>/dev/null && return 0     # already shimmed
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

# Front-load the lazy server download so there's a wrapper to shim before the first connection.
if ! server_present; then
    echo "cde-trust-serve-web: serve-web server not downloaded yet; front-loading it…"
    log="$(mktemp)"
    timeout 240 code serve-web --accept-server-license-terms --without-connection-token \
        --host 127.0.0.1 --port 0 >"$log" 2>&1 &
    dl=$!
    port=""
    for _ in $(seq 1 30); do
        # Parse the port from serve-web's "Web UI available at http://<host>:<port>" banner.
        # (If a VS Code version changes this wording, port stays empty -> download is skipped
        #  -> the build assertion fails / runtime no-ops. See the "IF THIS BREAKS" block.)
        port="$(grep -oE 'http://(127\.0\.0\.1|localhost):[0-9]+' "$log" 2>/dev/null | head -1 | grep -oE '[0-9]+$')"
        [ -n "$port" ] && break
        sleep 1
    done
    # The server downloads on the first HTTP hit — poke it until the wrapper lands.
    if [ -n "$port" ]; then
        for _ in $(seq 1 180); do
            curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null || true
            server_present && break
            sleep 1
        done
    fi
    # Killing the timeout parent SIGTERMs `code serve-web`, which supervises and tears down
    # the node server it spawned — verified in a fresh image that no serve-web/node process
    # is left behind, so a group-kill isn't needed here.
    kill "$dl" 2>/dev/null || true
    wait "$dl" 2>/dev/null || true
    rm -f "$log"
    sleep 2   # let extraction/rename settle
fi

changed=0
for cs in "$SW"/*/bin/code-server; do
    case "$cs" in *".staging/"*) continue ;; esac
    [ -f "$cs" ] || continue
    grep -qF "$SHIM_MARK" "$cs" 2>/dev/null && continue
    if shim_one "$cs"; then
        echo "cde-trust-serve-web: shimmed $cs with --disable-workspace-trust"
        changed=1
    fi
done

if [ "$changed" -eq 0 ]; then
    echo "cde-trust-serve-web: no change (already shimmed, or server unavailable)"
fi
exit 0
