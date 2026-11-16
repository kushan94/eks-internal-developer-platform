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
#
# Usage: scripts/check-oidc.sh [--claims <run id>]
set -uo pipefail
cd "$(dirname "$0")/.."

TF=infra/bootstrap/github-oidc.tf
failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
note() { echo "  note  $*"; }

REPO="$(sed -n '/variable "github_repo"/,/^}/p' "$TF" | sed -n 's/^ *default *= *"\(.*\)".*/\1/p')"
[ -n "$REPO" ] || { echo "couldn't read github_repo from $TF"; exit 1; }

# role -> environments, from the Terraform: lines like  apply = ["aws-apply", "aws-destroy"]
roles() { sed -n '/github_roles = {/,/^  }/p' "$TF" | sed -n 's/^ *\([a-z-]*\) *= *\[\(.*\)\].*/\1 \2/p' | tr -d '",'; }
envs_of() { roles | awk -v r="$1" '$1 == r { $1 = ""; print $0 }'; }
# The subject claim a job in an environment presents. The trust policies compare it with StringEquals.
sub_for() { echo "repo:$REPO:environment:$1"; }
accepts() { # role subject: does the trust policy for this role accept this subject?
  local env
  for env in $(envs_of "$1"); do [ "$(sub_for "$env")" = "$2" ] && return 0; done
  return 1
}

echo "1. What each role's trust policy accepts (repo $REPO)"
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
check_sub "a job with no environment, on main" "repo:$REPO:ref:refs/heads/main" ""
check_sub "a pull request job with no environment" "repo:$REPO:pull_request" ""
check_sub "the same environment in another repository" "repo:someone-else/other:environment:aws-apply" ""
check_sub "the right repository with different capitals" "repo:$(echo "$REPO" | tr '[:lower:]' '[:upper:]'):environment:aws-apply" ""
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

echo "3. The GitHub environments"
if ! command -v gh > /dev/null || ! gh auth status > /dev/null 2>&1; then
  note "gh isn't installed or logged in, so the environments weren't checked"
else
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

if [ "${1:-}" = --claims ]; then
  run="${2:?usage: --claims <run id>}"
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

echo
if [ "$failures" = 0 ]; then echo "The OIDC trust matches what GitHub will send."; else echo "$failures check(s) failed."; exit 1; fi
