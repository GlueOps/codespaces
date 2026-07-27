#!/usr/bin/env bash
# cde-trust-serve-web — disable VS Code "Workspace Trust" for `code serve-web`.
#
# The CDE web UI is served by `code serve-web`, which runs the workbench in the BROWSER.
# In that mode the usual ways to disable Workspace Trust do NOT work:
#   - user settings live in the browser, so a server-side settings.json is ignored for the
#     application-scoped `security.workspace.trust.enabled`;
#   - `product.json` `configurationDefaults` don't reach the browser either;
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
# server is downloaded lazily on first use, so if it isn't present yet we front-load the
# download (then stop it) so the very first connection is prompt-free too.

set -u

SW="$HOME/.vscode/cli/serve-web"
NEEDLE='enableWorkspaceTrust:!this._environmentService.args["disable-workspace-trust"]'
SEDEXPR='s/enableWorkspaceTrust:!this\._environmentService\.args\["disable-workspace-trust"\]/enableWorkspaceTrust:false/g'

# Ensure the serve-web server is downloaded so there's a server-main.js to patch.
if ! ls "$SW"/*/out/server-main.js >/dev/null 2>&1; then
    echo "cde-trust-serve-web: serve-web server not present; downloading it first…"
    timeout 180 code serve-web --accept-server-license-terms --without-connection-token --port 0 >/dev/null 2>&1 &
    dl=$!
    for _ in $(seq 1 180); do
        ls "$SW"/*/out/server-main.js >/dev/null 2>&1 && break
        sleep 1
    done
    kill "$dl" >/dev/null 2>&1 || true
    wait "$dl" 2>/dev/null || true
fi

changed=0
for f in "$SW"/*/out/server-main.js; do
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
