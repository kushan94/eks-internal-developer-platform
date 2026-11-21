#!/usr/bin/env bash
# Gives an application repo what the App deploy workflow needs to push to ECR:
# an aws-build environment that only main can use, holding that repo's own
# push-only key. Run after `make bootstrap` has created the repo's registry.
# Usage: scripts/app-repo-setup.sh <repo name> [owner]
# Secrets are piped to gh and never printed.
set -euo pipefail

name="${1:?usage: app-repo-setup.sh <repo name> [owner]}"
owner="${2:-$(gh repo view --json owner --jq .owner.login)}"
repo="$owner/$name"

keys="$(terraform -chdir=infra/bootstrap output -json app_image_push_keys)"
[ "$(jq --arg n "$name" 'has($n)' <<< "$keys")" = true ] \
  || { echo "No registry for $name. Add apps/$name.yaml, merge it and run make bootstrap." >&2; exit 1; }

[ "$(gh repo view "$repo" --json visibility --jq .visibility)" = "PUBLIC" ] \
  || { echo "$repo isn't public, so its environment can't be limited to main." >&2; exit 1; }

# Only main can use the key, so a branch or a fork pull request never sees it.
gh api -X PUT "repos/$repo/environments/aws-build" --silent --input - <<JSON
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api "repos/$repo/environments/aws-build/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main \
  || gh api -X POST "repos/$repo/environments/aws-build/deployment-branch-policies" -f name=main -f type=branch --silent

jq -r --arg n "$name" '.[$n].access_key_id' <<< "$keys" | tr -d '\n' | gh secret set AWS_ACCESS_KEY_ID --repo "$repo" --env aws-build
jq -r --arg n "$name" '.[$n].secret_access_key' <<< "$keys" | tr -d '\n' | gh secret set AWS_SECRET_ACCESS_KEY --repo "$repo" --env aws-build

echo "$repo's aws-build environment is ready."
