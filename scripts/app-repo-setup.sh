#!/usr/bin/env bash
# Gives an application repo what the App deploy workflow needs to push to ECR:
# its own push-only key, as two repository secrets. (Environment secrets would
# let only main use the key, but they don't reach a called workflow.) Run after
# `make bootstrap` has created the repo's registry.
# Usage: scripts/app-repo-setup.sh <repo name> [owner]
# Secrets are piped to gh and never printed.
set -euo pipefail

name="${1:?usage: app-repo-setup.sh <repo name> [owner]}"
owner="${2:-$(gh repo view --json owner --jq .owner.login)}"
repo="$owner/$name"

keys="$(terraform -chdir=infra/bootstrap output -json app_image_push_keys)"
[ "$(jq --arg n "$name" 'has($n)' <<< "$keys")" = true ] \
  || { echo "No registry for $name. Add apps/$name.yaml, merge it and run make bootstrap." >&2; exit 1; }

jq -r --arg n "$name" '.[$n].access_key_id' <<< "$keys" | tr -d '\n' | gh secret set AWS_ACCESS_KEY_ID --repo "$repo"
jq -r --arg n "$name" '.[$n].secret_access_key' <<< "$keys" | tr -d '\n' | gh secret set AWS_SECRET_ACCESS_KEY --repo "$repo"

echo "$repo's ECR key is stored as repository secrets."
