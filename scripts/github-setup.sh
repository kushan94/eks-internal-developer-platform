#!/usr/bin/env bash
# Creates the GitHub environments for the infrastructure workflow and stores
# the bootstrap stack's outputs as environment secrets. Run after `make bootstrap`.
# Secrets are piped to gh and never printed.
set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
ALLOWED_CIDR="${ALLOWED_CIDR:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32}"
APPROVER_ID="$(gh api user --jq .id)"
# Cluster admins: the IAM role behind your current aws login session, unless set.
if [ -z "${CLUSTER_ADMIN_ARNS:-}" ]; then
  caller="$(aws sts get-caller-identity --query Arn --output text)"
  role_name="$(printf '%s' "$caller" | sed -nE 's#^arn:aws:sts::[0-9]+:assumed-role/([^/]+)/.*#\1#p')"
  [ -n "$role_name" ] || { echo "Set CLUSTER_ADMIN_ARNS, or run this signed in with aws login." >&2; exit 1; }
  CLUSTER_ADMIN_ARNS="[\"$(aws iam get-role --role-name "$role_name" --query Role.Arn --output text)\"]"
fi
out() { terraform -chdir=infra/bootstrap output -raw "$1"; }

# The platform's domain isn't committed. The workflows read it from this
# repository variable: IDP_DOMAIN, or platform_domain in the bootstrap tfvars.
IDP_DOMAIN="${IDP_DOMAIN:-$(awk -F'"' '/^platform_domain/ {print $2}' infra/bootstrap/terraform.tfvars 2>/dev/null)}"
[ -n "$IDP_DOMAIN" ] || { echo "Set IDP_DOMAIN, or platform_domain in infra/bootstrap/terraform.tfvars." >&2; exit 1; }
gh variable set IDP_DOMAIN --repo "$REPO" --body "$IDP_DOMAIN"

# Plans run for pull requests, so this environment has no branch restriction.
gh api -X PUT "repos/$REPO/environments/aws-plan" --silent

# The Backstage image workflow, which only runs on main.
gh api -X PUT "repos/$REPO/environments/aws-build" --silent

# Required reviewers and branch rules only work on public repos with GitHub Free.
if [ "$(gh repo view "$REPO" --json visibility --jq .visibility)" = "PUBLIC" ]; then
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
else
  echo "Warning: $REPO is private, so aws-apply can't require approval or be limited to main." >&2
  echo "Run this script again after making the repo public to add those protections." >&2
  gh api -X PUT "repos/$REPO/environments/aws-apply" --silent
  gh api -X PUT "repos/$REPO/environments/aws-destroy" --silent
fi

set_secret() { gh secret set "$2" --repo "$REPO" --env "$1"; }
for env in aws-plan aws-apply aws-destroy; do
  out state_bucket | set_secret "$env" TF_STATE_BUCKET
  printf '%s' "$ALLOWED_CIDR" | set_secret "$env" ALLOWED_CIDR
  printf '%s' "$CLUSTER_ADMIN_ARNS" | set_secret "$env" CLUSTER_ADMIN_ARNS
done
out github_plan_access_key_id | set_secret aws-plan AWS_ACCESS_KEY_ID
out github_plan_secret_access_key | set_secret aws-plan AWS_SECRET_ACCESS_KEY
for env in aws-apply aws-destroy; do
  out github_apply_access_key_id | set_secret "$env" AWS_ACCESS_KEY_ID
  out github_apply_secret_access_key | set_secret "$env" AWS_SECRET_ACCESS_KEY
done
out github_image_push_access_key_id | set_secret aws-build AWS_ACCESS_KEY_ID
out github_image_push_secret_access_key | set_secret aws-build AWS_SECRET_ACCESS_KEY

# The OIDC roles that replace those keys. Their ARNs contain the account ID,
# so they're secrets rather than values in the workflows.
out github_plan_role_arn | set_secret aws-plan AWS_ROLE_ARN
for env in aws-apply aws-destroy; do
  out github_apply_role_arn | set_secret "$env" AWS_ROLE_ARN
done
out github_image_push_role_arn | set_secret aws-build AWS_ROLE_ARN

echo "Environments and secrets are set for $REPO."
