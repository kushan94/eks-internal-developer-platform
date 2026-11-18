#!/usr/bin/env bash
# Tests what the CI identities can and can't do, with the IAM policy simulator.
# It evaluates the real attached policies and creates nothing. It tests the
# three IAM users (github-plan, github-apply, github-image-push), which have the
# same policy documents as the roles in infra/bootstrap/github-oidc.tf will,
# so the roles can be switched on later knowing what they may do.
#
# Needs: a valid AWS session (aws login) as someone who may call iam:Get* and
# iam:SimulatePrincipalPolicy, and the bootstrap state from `make bootstrap`
# (for the state bucket and ECR repository names).
# Usage: scripts/check-ci-role-permissions.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

STATE=infra/bootstrap/terraform.tfstate
failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
note() { echo "  note  $*"; }

command -v jq > /dev/null || { echo "jq is needed"; exit 2; }
[ -f "$STATE" ] || { echo "No $STATE. Run make bootstrap first: this reads the state bucket and ECR repository from it."; exit 2; }
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2> /dev/null)" || { echo "No AWS session. Run: aws login"; exit 2; }

BUCKET="$(jq -r '.outputs.state_bucket.value' "$STATE")"
REPO_ARN="$(jq -r '.resources[] | select(.type == "aws_ecr_repository" and .name == "backstage") | .instances[0].attributes.arn' "$STATE")"
[ -n "$BUCKET" ] && [ "$REPO_ARN" != null ] && [ -n "$REPO_ARN" ] || { echo "couldn't read the bucket or ECR repository from the state"; exit 2; }
REGION="$(cut -d: -f4 <<< "$REPO_ARN")"
OTHER_REPO="arn:aws:ecr:$REGION:$ACCOUNT:repository/some-other-repository"
SECRET="arn:aws:secretsmanager:$REGION:$ACCOUNT:secret"

# The account ID isn't printed.
mask() { sed "s/$ACCOUNT/<account>/g"; }
# The organization's policy depends on the region a request goes to, and the
# simulator only knows it if told. Without it, regional actions look denied.
region_context() { echo "ContextKeyName=aws:RequestedRegion,ContextKeyValues=${1:-$REGION},ContextKeyType=string"; }
decision() { # user action resource [region]
  aws iam simulate-principal-policy --policy-source-arn "$(arn_of "$1")" --action-names "$2" --resource-arns "$3" \
    --context-entries "$(region_context "${4:-}")" --query 'EvaluationResults[0].EvalDecision' --output text 2> /dev/null
}
# Looked up once per user. (macOS's bash 3.2 has no associative arrays.)
arn_of() {
  case "$1" in
    github-plan) echo "$PLAN_ARN" ;;
    github-apply) echo "$APPLY_ARN" ;;
    github-image-push) echo "$IMAGE_ARN" ;;
  esac
}

check() { # user allow|deny action resource description
  local user="$1" want="$2" action="$3" resource="$4" desc="$5" got
  got="$(decision "$user" "$action" "$resource")"
  case "$got" in
    allowed) [ "$want" = allow ] && pass "$user can $desc" || fail "$user CAN $desc ($action on $(mask <<< "$resource"))" ;;
    implicitDeny | explicitDeny) [ "$want" = deny ] && pass "$user can't $desc" || fail "$user can't $desc, but should be able to ($got: $action on $(mask <<< "$resource"))" ;;
    *) fail "$user: the simulator gave no answer for $action (is the user missing, or the session too limited?)" ;;
  esac
}

for u in github-plan github-apply github-image-push; do
  arn="$(aws iam get-user --user-name "$u" --query User.Arn --output text 2> /dev/null)" || { echo "The IAM user $u doesn't exist in this account, or this session can't read it."; exit 2; }
  case "$u" in github-plan) PLAN_ARN="$arn" ;; github-apply) APPLY_ARN="$arn" ;; github-image-push) IMAGE_ARN="$arn" ;; esac
done

echo "github-plan: reads the account, takes the state lock, writes nothing else"
check github-plan allow ec2:DescribeVpcs '*' "describe VPCs"
check github-plan allow eks:DescribeCluster '*' "describe EKS clusters"
check github-plan allow iam:GetRole '*' "read IAM roles"
check github-plan allow s3:GetObject "arn:aws:s3:::$BUCKET/eks/terraform.tfstate" "read the Terraform state"
check github-plan allow s3:PutObject "arn:aws:s3:::$BUCKET/eks/terraform.tfstate.tflock" "take the state lock"
check github-plan allow s3:DeleteObject "arn:aws:s3:::$BUCKET/eks/terraform.tfstate.tflock" "release the state lock"
check github-plan allow secretsmanager:GetSecretValue "$SECRET:idp/backstage/database-AbCdEf" "read the database secret it refreshes"
check github-plan deny s3:PutObject "arn:aws:s3:::$BUCKET/eks/terraform.tfstate" "write the Terraform state"
check github-plan deny s3:DeleteObject "arn:aws:s3:::$BUCKET/eks/terraform.tfstate" "delete the Terraform state"
check github-plan deny secretsmanager:GetSecretValue "$SECRET:idp/backstage/github-app-AbCdEf" "read another secret"
check github-plan deny iam:CreateRole '*' "create IAM roles"
check github-plan deny ec2:RunInstances '*' "launch instances"
check github-plan deny eks:CreateCluster '*' "create a cluster"
check github-plan deny s3:DeleteBucket "arn:aws:s3:::$BUCKET" "delete the state bucket"

echo "github-image-push: pushes to the Backstage repository and nothing else"
check github-image-push allow ecr:GetAuthorizationToken '*' "get a registry login"
check github-image-push allow ecr:InitiateLayerUpload "$REPO_ARN" "upload layers to the Backstage repository"
check github-image-push allow ecr:PutImage "$REPO_ARN" "push an image to the Backstage repository"
check github-image-push deny ecr:PutImage "$OTHER_REPO" "push to another repository"
check github-image-push deny ecr:BatchDeleteImage "$REPO_ARN" "delete images"
check github-image-push deny ecr:DeleteRepository "$REPO_ARN" "delete the repository"
check github-image-push deny ecr:CreateRepository '*' "create repositories"
check github-image-push deny s3:GetObject "arn:aws:s3:::$BUCKET/eks/terraform.tfstate" "read the state"
check github-image-push deny iam:CreateRole '*' "create IAM roles"

echo "github-apply: administrator, by design, and only reachable from main (see check-oidc.sh)"
check github-apply allow iam:CreateRole '*' "create IAM roles"
check github-apply allow eks:CreateCluster '*' "create a cluster"
check github-apply allow s3:PutObject "arn:aws:s3:::$BUCKET/eks/terraform.tfstate" "write the Terraform state"

echo "The organization's rules (from its service control policy, not the users' own policies)"
for other in us-east-1 us-west-2 eu-west-1; do
  got="$(decision github-apply eks:CreateCluster '*' "$other")"
  case "$got" in
    explicitDeny) pass "requests to $other are refused by the organization, even for the administrator" ;;
    allowed) note "requests to $other are allowed. The organization doesn't restrict that region" ;;
    *) fail "no answer for $other" ;;
  esac
done
echo "The organization's block on the OIDC provider (what the support case is about)"
org="$(aws iam simulate-principal-policy --policy-source-arn "$(arn_of github-apply)" --action-names iam:CreateOpenIDConnectProvider --resource-arns '*' \
  --context-entries "$(region_context)" --query 'EvaluationResults[0].[EvalDecision, OrganizationsDecisionDetail.AllowedByOrganizations]' --output text 2> /dev/null | tr '\t' ' ')"
case "$org" in
  "allowed True") note "AWS now allows creating the OIDC provider. PR #37 can go ahead." ;;
  *Deny*) note "still blocked ($org). The roles can't be created until AWS lifts it." ;;
  *) note "couldn't tell what the organization allows (the simulator answered: '${org:-nothing}')" ;;
esac

echo
if [ "$failures" = 0 ]; then echo "The CI identities can do what they should and no more."; else echo "$failures check(s) failed."; exit 1; fi
