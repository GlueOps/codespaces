#!/usr/bin/env bash
# cde-init — GlueOps CDE default bootstrap.
#
# Runs inside the codespace container at `dev` startup (invoked by developer-setup.sh when
# CDE_SETUP_SCRIPT resolves to `cde-init`), or manually. Reads its inputs from the container
# environment, which is populated from /etc/glueops/codespace.env by the Slack bot. Every
# step is guarded and best-effort: an unconfigured input is skipped, and no failure aborts
# the CDE — the developer still gets a working environment.
#
#   GITHUB_TOKEN                                      -> non-interactive `gh` auth + git creds
#   GLUEOPS_CDE_CLONE_REPO                            -> clone into /workspaces/glueops/<repo>
#   GLUEKUBE_SSH_AUTOGLUE_{PROD,NONPROD}_{URL,TOKEN}  -> seed gluekube_ssh (AutoGlue) profiles

export GIT_TERMINAL_PROMPT=0   # never hang on a credential prompt (e.g. private repo, no token)

# --- GitHub auth from token (only if provided and not already authenticated) ---
if [ -n "${GITHUB_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
    echo "cde-init: authenticating gh from GITHUB_TOKEN"
    tok="$GITHUB_TOKEN"; unset GITHUB_TOKEN   # gh refuses --with-token while the env var is set
    if printf '%s' "$tok" | gh auth login -h github.com -p https --with-token; then
        gh auth setup-git
        # best-effort git identity so commits work immediately (mirrors yolo.sh)
        email="$(gh api /user/emails -q '.[] | select(.primary).email' 2>/dev/null || true)"
        name="$(gh api user -q .name 2>/dev/null || true)"
        [ -n "$email" ] && git config --global user.email "$email"
        [ -n "$name" ]  && git config --global user.name  "$name"
    else
        echo "cde-init: gh auth failed (continuing)"
    fi
fi

# --- Clone the requested repo (public works without a token; idempotent) ---
if [ -n "${GLUEOPS_CDE_CLONE_REPO:-}" ]; then
    dest="/workspaces/glueops/$(basename "${GLUEOPS_CDE_CLONE_REPO%.git}")"
    if [ -e "$dest/.git" ]; then
        echo "cde-init: repo already present at $dest"
    else
        echo "cde-init: cloning $GLUEOPS_CDE_CLONE_REPO -> $dest"
        git clone "$GLUEOPS_CDE_CLONE_REPO" "$dest" \
            || echo "cde-init: clone failed (private repo? set GITHUB_TOKEN) — continuing"
    fi
fi

# --- Seed gluekube_ssh AutoGlue profiles from env (token-gated, idempotent) ---
# gluekube_ssh stores profiles in ~/.config/autoglue-ssh/config.json as
# {name, api_key, api_endpoint}; it does not read env vars, so we seed the file here.
autoglue_cfg="$HOME/.config/autoglue-ssh/config.json"
seed_autoglue() {  # name url token
    local name="$1" url="$2" token="$3" tmp
    [ -z "$token" ] && return 0    # only seed when a token is provided
    [ -z "$url" ] && return 0
    mkdir -p "$(dirname "$autoglue_cfg")"
    [ -f "$autoglue_cfg" ] || echo '{"profiles":[]}' > "$autoglue_cfg"
    if jq -e --arg n "$name" '.profiles[]? | select(.name == $n)' "$autoglue_cfg" >/dev/null 2>&1; then
        return 0                   # keep an existing profile of that name (never clobber)
    fi
    tmp="$(mktemp)"
    if jq --arg n "$name" --arg k "$token" --arg e "$url" \
        '.profiles += [{"name": $n, "api_key": $k, "api_endpoint": $e}]' "$autoglue_cfg" > "$tmp"; then
        mv "$tmp" "$autoglue_cfg"
        echo "cde-init: seeded AutoGlue profile '$name'"
    else
        rm -f "$tmp"
    fi
}
if command -v jq >/dev/null 2>&1; then
    seed_autoglue prod    "${GLUEKUBE_SSH_AUTOGLUE_PROD_URL:-}"    "${GLUEKUBE_SSH_AUTOGLUE_PROD_TOKEN:-}"
    seed_autoglue nonprod "${GLUEKUBE_SSH_AUTOGLUE_NONPROD_URL:-}" "${GLUEKUBE_SSH_AUTOGLUE_NONPROD_TOKEN:-}"
fi

echo "cde-init: done"
