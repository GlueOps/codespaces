#!/usr/bin/env bash
# cde-trust-serve-web — disable VS Code "Workspace Trust" for `code serve-web`.
#
# The CDE web UI is served by `code serve-web`, which runs the workbench in the BROWSER.
# In that mode the usual ways to disable Workspace Trust do NOT work:
#   - user settings live in the browser, so a server-side settings.json is ignored for the
#     application-scoped `security.workspace.trust.enabled`;
#   - `product.json` `configurationDefaults` don't reach the browser workbench;
#   - `code serve-web` refuses to forward the server's `--disable-workspace-trust` flag
#     ("unexpected argument").
#
# The workbench decides trust with:
#     isWorkspaceTrustEnabled = disableWorkspaceTrust ? false : <config value>
#     disableWorkspaceTrust   = !options.enableWorkspaceTrust
# and the server (server-main.js) sets that option from the CLI flag:
#     enableWorkspaceTrust: !args["disable-workspace-trust"]
# So we patch server-main.js to force `enableWorkspaceTrust:false`, which makes
# disableWorkspaceTrust true and short-circuits the "Do you trust the authors…" prompt off
# for every folder — without reading any setting. Idempotent and non-fatal.
#
# Called from developer-setup.sh's `dev` before `code serve-web` launches. The serve-web
# SERVER (server-main.js) is downloaded lazily on the first browser CONNECTION, not at
# `serve-web` startup — so if it isn't present yet we briefly start serve-web and poke its
# port with curl to trigger the download, then patch. That makes even the first real
# connection prompt-free.

set -u

SW="$HOME/.vscode/cli/serve-web"
NEEDLE='enableWorkspaceTrust:!this._environmentService.args["disable-workspace-trust"]'
SEDEXPR='s/enableWorkspaceTrust:!this\._environmentService\.args\["disable-workspace-trust"\]/enableWorkspaceTrust:false/g'

# True when a fully-extracted server exists (ignore the transient "<hash>.staging" dir).
server_present() {
    local f
    for f in "$SW"/*/out/server-main.js; do
        case "$f" in *".staging/"*) continue ;; esac
        [ -f "$f" ] && return 0
    done
    return 1
}

if ! server_present; then
    echo "cde-trust-serve-web: serve-web server not present; triggering its download…"
    log="$(mktemp)"
    timeout 240 code serve-web --accept-server-license-terms --without-connection-token \
        --host 127.0.0.1 --port 0 >"$log" 2>&1 &
    dl=$!
    # Discover the random port serve-web picked.
    port=""
    for _ in $(seq 1 30); do
        port="$(grep -oE 'http://127\.0\.0\.1:[0-9]+' "$log" 2>/dev/null | head -1 | grep -oE '[0-9]+$')"
        [ -n "$port" ] && break
        sleep 1
    done
    # The server downloads lazily on the first HTTP hit — poke it until server-main.js lands.
    if [ -n "$port" ]; then
        for _ in $(seq 1 180); do
            curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null || true
            server_present && break
            sleep 1
        done
    fi
    kill "$dl" 2>/dev/null || true
    wait "$dl" 2>/dev/null || true
    rm -f "$log"
    sleep 2   # let extraction/rename settle
fi

changed=0
for f in "$SW"/*/out/server-main.js; do
    case "$f" in *".staging/"*) continue ;; esac
    [ -f "$f" ] || continue
    if grep -qF "$NEEDLE" "$f"; then
        if sed -i "$SEDEXPR" "$f"; then
            echo "cde-trust-serve-web: disabled Workspace Trust in $f"
            changed=1
        fi
    fi
done

if [ "$changed" -eq 0 ]; then
    echo "cde-trust-serve-web: no change (already patched, or server missing / pattern changed)"
fi
exit 0
