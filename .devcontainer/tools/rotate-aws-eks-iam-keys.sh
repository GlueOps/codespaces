#!/usr/bin/env bash
# Rotate the AWS key pair in ./.env  --  create, verify, write, delete old.
# .env is only touched after the new key is confirmed working.
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || { echo "Error: $ENV_FILE not found." >&2; exit 1; }

# Strip the prefix, then trim whitespace/quotes at the ends (your .env has
# trailing spaces; leaving them on the region or key ID breaks every AWS call).
get() { grep -m1 "^export $1=" "$ENV_FILE" | sed "s/^export $1=//; s/^[[:space:]\"']*//; s/[[:space:]\"']*\$//"; }

OLD_KEY_ID=$(get AWS_ACCESS_KEY_ID || true)
OLD_SECRET=$(get AWS_SECRET_ACCESS_KEY || true)
[ -n "$OLD_KEY_ID" ] && [ -n "$OLD_SECRET" ] || { echo "Error: no credentials in $ENV_FILE." >&2; exit 1; }

# A stale session token in the shell silently invalidates the key pair below.
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_ACCESS_KEY_ID="$OLD_KEY_ID" AWS_SECRET_ACCESS_KEY="$OLD_SECRET"
export AWS_DEFAULT_REGION="$(get AWS_DEFAULT_REGION || true)"
[ -n "$AWS_DEFAULT_REGION" ] || export AWS_DEFAULT_REGION=us-west-2

USER=$(aws sts get-caller-identity --query Arn --output text --no-cli-pager)
USER="${USER##*/}"
echo "User: $USER  |  rotating $OLD_KEY_ID"

IFS=$'\t' read -r NEW_KEY_ID NEW_SECRET < <(aws iam create-access-key --user-name "$USER" \
    --query '[AccessKey.AccessKeyId,AccessKey.SecretAccessKey]' --output text --no-cli-pager)
echo "Created $NEW_KEY_ID"

# IAM caps you at 2 keys, so bin the new one if anything below fails.
trap '[ -n "${DONE:-}" ] || { AWS_ACCESS_KEY_ID=$OLD_KEY_ID AWS_SECRET_ACCESS_KEY=$OLD_SECRET \
    aws iam delete-access-key --user-name "$USER" --access-key-id "$NEW_KEY_ID" --no-cli-pager 2>/dev/null; \
    echo "Aborted; old key still active." >&2; }' EXIT

export AWS_ACCESS_KEY_ID="$NEW_KEY_ID" AWS_SECRET_ACCESS_KEY="$NEW_SECRET"
for i in $(seq 20); do
    aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1 && break
    [ "$i" = 20 ] && { echo "Error: new key never became usable." >&2; exit 1; }
    sleep 3
done

export NEW_KEY_ID NEW_SECRET
perl -i -pe 's/^(export AWS_ACCESS_KEY_ID=).*/$1$ENV{NEW_KEY_ID}/;
             s/^(export AWS_SECRET_ACCESS_KEY=).*/$1$ENV{NEW_SECRET}/' "$ENV_FILE"
grep -qF "=$NEW_KEY_ID" "$ENV_FILE" || { echo "Error: $ENV_FILE not updated." >&2; exit 1; }

DONE=1
aws iam delete-access-key --user-name "$USER" --access-key-id "$OLD_KEY_ID" --no-cli-pager
echo "Done. Deleted $OLD_KEY_ID -- run: source $ENV_FILE"
