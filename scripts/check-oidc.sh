#!/usr/bin/env bash
# Tests what GitHub's OIDC sign-in to AWS depends on, without AWS and without
# the OIDC provider, which the account can't create yet.
#
#   1. The trust policies in infra/bootstrap/github-oidc.tf accept exactly the
#      GitHub environments they should, and nothing else.
#   2. The workflows only use environments the trust policies know.
#   3. The GitHub environments exist, and the ones that apply or destroy
#      infrastructure only run from main.
#   4. With --claims <run id>, the claims GitHub put in a real token (from the
#      "OIDC claims" workflow) match what the trust policies compare.
#   5. With --terraform, Terraform itself (in Docker, in a copy under .test/)
#      renders the same subject prefix and roles this script assumes. This
#      script reads the HCL as text, so a mistake in an expression could
#      otherwise slip past it. The first run downloads the AWS provider.
#
# Usage: scripts/check-oidc.sh [--claims <run id>] [--terraform]
set -uo pipefail
cd "$(dirname "$0")/.."

TF=infra/bootstrap/github-oidc.tf
failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
note() { echo "  note  $*"; }

default_of() { sed -n "/variable \"$1\"/,/^}/p" "$TF" | sed -n 's/^ *default *= *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p'; }
REPO="$(default_of github_repo)" OWNER_ID="$(default_of github_owner_id)" REPO_ID="$(default_of github_repo_id)"
[ -n "$REPO" ] && [ -n "$OWNER_ID" ] && [ -n "$REPO_ID" ] || { echo "couldn't read github_repo, github_owner_id and github_repo_id from $TF"; exit 1; }
# GitHub puts the owner's and the repository's numeric IDs in the subject (immutable subjects).
prefix_for() { echo "repo:${1%%/*}@$OWNER_ID/${1#*/}@$REPO_ID"; }
PREFIX="$(prefix_for "$REPO")"

# role -> environments, from the Terraform: lines like  apply = ["aws-apply", "aws-destroy"]
roles() { sed -n '/github_roles = {/,/^  }/p' "$TF" | sed -n 's/^ *\([a-z-]*\) *= *\[\(.*\)\].*/\1 \2/p' | tr -d '",'; }
envs_of() { roles | awk -v r="$1" '$1 == r { $1 = ""; print $0 }'; }
# The subject claim a job in an environment presents. The trust policies compare it with StringEquals.
sub_for() { echo "$PREFIX:environment:$1"; }
accepts() { # role subject: does the trust policy for this role accept this subject?
  local env
  for env in $(envs_of "$1"); do [ "$(sub_for "$env")" = "$2" ] && return 0; done
  return 1
}

echo "1. What each role's trust policy accepts (subjects start with $PREFIX)"
# What each role should accept. Changing this is changing who can get what.
want() { case "$1" in plan) echo "aws-plan" ;; apply) echo "aws-apply aws-destroy" ;; image-push) echo "aws-build" ;; esac; }
for role in plan apply image-push; do
  got="$(envs_of "$role" | xargs -n1 | sort | xargs)"
  expected="$(want "$role" | xargs -n1 | sort | xargs)"
  [ "$got" = "$expected" ] && pass "github-$role trusts: $got" || fail "github-$role trusts '$got', expected '$expected'"
done
[ "$(roles | wc -l | tr -d ' ')" = 3 ] && pass "there are exactly three roles" || fail "unexpected roles: $(roles | cut -d' ' -f1 | xargs)"

# Tokens that should get nothing, or only one role.
check_sub() { # description subject expected-roles
  local desc="$1" sub="$2" expected="$3" got="" role
  for role in plan apply image-push; do accepts "$role" "$sub" && got="$got $role"; done
  got="$(echo $got)"
  [ "$got" = "$expected" ] && pass "$desc -> ${got:-no role}" || fail "$desc -> '${got:-no role}', expected '${expected:-no role}'"
}
check_sub "a job in aws-plan" "$(sub_for aws-plan)" "plan"
check_sub "a job in aws-apply" "$(sub_for aws-apply)" "apply"
check_sub "a job in aws-destroy (the nightly destroy)" "$(sub_for aws-destroy)" "apply"
check_sub "a job in aws-build" "$(sub_for aws-build)" "image-push"
check_sub "a job with no environment, on main" "$PREFIX:ref:refs/heads/main" ""
check_sub "a pull request job with no environment" "$PREFIX:pull_request" ""
check_sub "the same environment in another repository" "repo:someone-else@1/other@2:environment:aws-apply" ""
check_sub "the same name with a different repository ID (a recreated repository)" "repo:${REPO%%/*}@$OWNER_ID/${REPO#*/}@1:environment:aws-apply" ""
check_sub "the old subject format, without IDs" "repo:$REPO:environment:aws-apply" ""
check_sub "the right repository with different capitals" "$(echo "$PREFIX" | tr '[:lower:]' '[:upper:]'):environment:aws-apply" ""
check_sub "an environment nobody has heard of" "$(sub_for aws-admin)" ""

grep -q 'values *= *\["sts.amazonaws.com"\]' "$TF" && pass "the trust policies require the audience sts.amazonaws.com" || fail "no audience condition"
grep -q 'url *= *"https://token.actions.githubusercontent.com"' "$TF" && pass "the provider is GitHub's token issuer" || fail "unexpected provider URL"
# The operator on the line before the subject's condition, not any StringEquals in the file.
sub_test="$(awk '/^ *test *=/ { t = $0 } /:sub"/ { print t }' "$TF")"
[ -n "$sub_test" ] && grep -q '"StringEquals"' <<< "$sub_test" && pass "the subject is compared exactly (StringEquals), not with a wildcard" || fail "the subject condition isn't an exact match: ${sub_test:-not found}"

echo "2. The workflows use only environments the trust policies know"
known="$(roles | cut -d' ' -f2- | xargs -n1 | sort -u | xargs)"
used=""
for f in .github/workflows/*.yml; do
  for env in $(grep -E '^ *environment:' "$f" | grep -oE "aws-[a-z]+"); do used="$used $env"; done
done
used="$(echo "$used" | xargs -n1 | sort -u | xargs)"
bad=0
for env in $used; do
  echo " $known " | grep -q " $env " || { fail "a workflow uses the environment $env, which no role trusts"; bad=1; }
done
[ $bad = 0 ] && pass "workflows use: $used (all trusted by a role)"

echo "3. GitHub: the subject format and the environments"
if ! command -v gh > /dev/null || ! gh auth status > /dev/null 2>&1; then
  note "gh isn't installed or logged in, so GitHub wasn't checked"
else
  # What GitHub says the subject starts with, which is what the trust policies must match.
  reported="$(gh api "repos/$REPO/actions/oidc/customization/sub" --jq '.sub_claim_prefix' 2> /dev/null)"
  immutable="$(gh api "repos/$REPO/actions/oidc/customization/sub" --jq '.use_immutable_subject' 2> /dev/null)"
  if [ "$reported" = "$PREFIX" ]; then pass "the Terraform subject prefix is the one GitHub reports for this repository"
  else fail "Terraform expects '$PREFIX' but GitHub reports '${reported:-nothing}' (immutable subjects: ${immutable:-unknown})"; fi
  for env in $known; do
    if ! gh api "repos/$REPO/environments/$env" > /dev/null 2>&1; then fail "the GitHub environment $env doesn't exist, so no job could get its role"; continue; fi
    branches="$(gh api "repos/$REPO/environments/$env/deployment-branch-policies" --jq '[.branch_policies[].name] | join(",")' 2> /dev/null)"
    custom="$(gh api "repos/$REPO/environments/$env" --jq '.deployment_branch_policy.custom_branch_policies // false')"
    case "$env" in
      aws-apply | aws-destroy)
        if [ "$custom" = true ] && [ "$branches" = main ]; then pass "$env exists and only deploys from main"
        else fail "$env must only deploy from main (custom policies: $custom, branches: '${branches:-none}')"; fi ;;
      *) pass "$env exists"; note "$env has no branch restriction, so a workflow on any branch of this repo can use its role" ;;
    esac
  done
fi

CLAIMS_RUN="" WITH_TERRAFORM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --claims) CLAIMS_RUN="${2:?usage: --claims <run id>}"; shift 2 ;;
    --terraform) WITH_TERRAFORM=1; shift ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
done

if [ -n "$CLAIMS_RUN" ]; then
  run="$CLAIMS_RUN"
  echo "4. The claims in a real token (run $run)"
  logs="$(gh run view "$run" --repo "$REPO" --log 2> /dev/null | grep -o 'CLAIMS {.*}' | sed 's/^CLAIMS //')"
  [ -n "$logs" ] || fail "no CLAIMS lines in that run's log"
  while IFS= read -r claims; do
    [ -z "$claims" ] && continue
    env="$(jq -r .environment <<< "$claims")" sub="$(jq -r .sub <<< "$claims")"
    [ "$sub" = "$(sub_for "$env")" ] && pass "$env: sub is $sub, exactly what the trust policy compares" || fail "$env: sub is '$sub', expected '$(sub_for "$env")'"
    [ "$(jq -r .aud <<< "$claims")" = sts.amazonaws.com ] && pass "$env: aud is sts.amazonaws.com" || fail "$env: aud is $(jq -r .aud <<< "$claims")"
    [ "$(jq -r .iss <<< "$claims")" = https://token.actions.githubusercontent.com ] && pass "$env: iss is GitHub's issuer" || fail "$env: iss is $(jq -r .iss <<< "$claims")"
    [ "$(jq -r .repository <<< "$claims")" = "$REPO" ] && pass "$env: repository matches, capitals included" || fail "$env: repository is $(jq -r .repository <<< "$claims")"
    role="$(for r in plan apply image-push; do accepts "$r" "$sub" && echo "github-$r"; done | xargs)"
    note "$env would be accepted by: ${role:-no role}"
  done <<< "$logs"
fi

if [ -n "$WITH_TERRAFORM" ]; then
  echo "5. Terraform renders what this script assumes"
  # The trust document's values come from this expression, so it must use the prefix.
  grep -qF 'values   = [for env in each.value : "${local.github_subject_prefix}:environment:${env}"]' "$TF" \
    && pass "the trust policy's subject values are built from the subject prefix and the environment" \
    || fail "the trust policy's subject values aren't built from local.github_subject_prefix"
  if ! command -v docker > /dev/null; then note "docker isn't available, so Terraform wasn't run"; else
    # Under the repository, because Docker only shares the home directory.
    work=.test/oidc-terraform
    rm -rf "$work"; mkdir -p "$work"
    cp infra/bootstrap/*.tf "$work"/; cp infra/bootstrap/.terraform.lock.hcl "$work"/ 2> /dev/null
    rendered="$(docker run --rm --entrypoint sh -v "$PWD/$work":/workspace -w /workspace "${TF_IMAGE:-hashicorp/terraform:latest}" -c \
      'terraform init -backend=false -input=false > /dev/null 2>&1 && echo "jsonencode({prefix = local.github_subject_prefix, roles = local.github_roles})" | terraform console -no-color 2> /dev/null' \
      | jq -r . 2> /dev/null | jq -c . 2> /dev/null)"
    if [ -z "$rendered" ]; then fail "Terraform couldn't render the locals (run it by hand in $work to see why)"; else
      [ "$(jq -r .prefix <<< "$rendered")" = "$PREFIX" ] && pass "Terraform's subject prefix is $PREFIX" || fail "Terraform renders the prefix '$(jq -r .prefix <<< "$rendered")', this script expects '$PREFIX'"
      for role in plan apply image-push; do
        tf_envs="$(jq -r --arg r "$role" '.roles[$r] | sort | join(" ")' <<< "$rendered")"
        [ "$tf_envs" = "$(envs_of "$role" | xargs -n1 | sort | xargs)" ] && pass "Terraform renders github-$role's environments as: $tf_envs" || fail "github-$role: Terraform says '$tf_envs', this script read '$(envs_of "$role" | xargs)'"
      done
    fi
  fi
fi

echo
if [ "$failures" = 0 ]; then echo "The OIDC trust matches what GitHub will send."; else echo "$failures check(s) failed."; exit 1; fi
