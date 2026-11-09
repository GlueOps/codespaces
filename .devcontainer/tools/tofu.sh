#!/bin/bash
# tofu (and terraform, a symlink to it) for the codespace. When ~/.tofurc points the
# registries at a tofu-cache mirror (https://github.com/GlueOps/tofu-cache), commands
# that download also send GitHub module clones through it, and fall back to upstream
# if the mirror is unreachable. Delete ~/.tofurc to turn the mirror off.
set -u
real=/usr/local/libexec/tofu

# The subcommand is the first argument that isn't a global flag such as -chdir=dir.
sub=""; sub2=""
for a in "$@"; do
  case $a in
    -*) ;;
    *) if [ -z "$sub" ]; then sub=$a; else sub2=$a; break; fi ;;
  esac
done
case "$sub $sub2" in
  "init "* | "get "* | "providers lock" | "providers mirror") ;;
  *) exec "$real" "$@" ;;
esac

mirror=""
if [ -z "${TF_CLI_CONFIG_FILE:-}${TERRAFORM_CONFIG:-}" ] && [ -f "${HOME:-}/.tofurc" ]; then
  mirror=$(sed -n 's#^[[:space:]]*"providers\.v1"[[:space:]]*=[[:space:]]*"\(https://[^"]*\)/repository/tofu/registry\.opentofu\.org/v1/providers/".*#\1#p' "$HOME/.tofurc" | head -n1)
fi
[ -n "$mirror" ] || exec "$real" "$@"

if ! curl -fsS -o /dev/null --connect-timeout 2 --max-time 3 \
  "$mirror/repository/tofu/registry.opentofu.org/v1/providers/hashicorp/null/versions" 2>/dev/null; then
  echo "tofu: mirror $mirror unreachable; using upstream directly" >&2
  TF_CLI_CONFIG_FILE=/dev/null exec "$real" "$@"
fi

# Only this process gets the rewrite, after any GIT_CONFIG_* already set. No prompt and
# no credential helper for the mirror: it is public-only and must never get a token.
n=${GIT_CONFIG_COUNT:-0}
[[ $n =~ ^(0|[1-9][0-9]*)$ ]] || n=0
export "GIT_CONFIG_KEY_$n=url.$mirror/repository/git/github.com/.insteadOf"
export "GIT_CONFIG_VALUE_$n=https://github.com/"
export "GIT_CONFIG_KEY_$((n + 1))=credential.$mirror/.helper"
export "GIT_CONFIG_VALUE_$((n + 1))="
export GIT_CONFIG_COUNT=$((n + 2)) GIT_TERMINAL_PROMPT=0
exec "$real" "$@"
