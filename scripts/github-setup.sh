#!/usr/bin/env bash
# Creates the GitHub environments for the infrastructure workflow and stores
# the bootstrap stack's outputs as environment secrets. Run after `make bootstrap`.
# Secrets are piped to gh and never printed.
set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
ALLOWED_CIDR="${ALLOWED_CIDR:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
APPROVER_ID="$(gh api user --jq .id)"
out() { terraform -chdir=infra/bootstrap output -raw "$1"; }

# Plans run for pull requests, so this environment has no branch restriction.
gh api -X PUT "repos/$REPO/environments/aws-plan" --silent

# Applies need your approval and can only run from main.
gh api -X PUT "repos/$REPO/environments/aws-apply" --silent --input - <<JSON
{"reviewers": [{"type": "User", "id": $APPROVER_ID}],
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON

# The nightly destroy runs without approval, but only from main.
gh api -X PUT "repos/$REPO/environments/aws-destroy" --silent --input - <<JSON
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON

for env in aws-apply aws-destroy; do
  if ! gh api "repos/$REPO/environments/$env/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main; then
    gh api -X POST "repos/$REPO/environments/$env/deployment-branch-policies" -f name=main -f type=branch --silent
  fi
done

set_secret() { gh secret set "$2" --repo "$REPO" --env "$1"; }
for env in aws-plan aws-apply aws-destroy; do
  out state_bucket | set_secret "$env" TF_STATE_BUCKET
  printf '%s' "$ALLOWED_CIDR" | set_secret "$env" ALLOWED_CIDR
done
out github_plan_access_key_id | set_secret aws-plan AWS_ACCESS_KEY_ID
out github_plan_secret_access_key | set_secret aws-plan AWS_SECRET_ACCESS_KEY
for env in aws-apply aws-destroy; do
  out github_apply_access_key_id | set_secret "$env" AWS_ACCESS_KEY_ID
  out github_apply_secret_access_key | set_secret "$env" AWS_SECRET_ACCESS_KEY
done

echo "Environments and secrets are set for $REPO."
