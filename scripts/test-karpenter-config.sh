#!/usr/bin/env bash
# Checks the Karpenter configuration for the mistakes that only show up on a
# running cluster: a NodePool that asks for Spot (the organization's policy
# denies it), no cap on what it may launch, and names that Terraform, the chart
# and the destroy script must agree on.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
yq() { docker run --rm -i mikefarah/yq:4.47.2 "$@"; }

rendered="$(helm template karpenter-config platform/karpenter --set clusterName=testcluster)" || { echo "the chart doesn't render"; exit 1; }
pool="$(yq 'select(.kind == "NodePool")' <<< "$rendered")"
class="$(yq 'select(.kind == "EC2NodeClass")' <<< "$rendered")"

echo "the NodePool"
capacity="$(yq -o=json -I=0 '.spec.template.spec.requirements[] | select(.key == "karpenter.sh/capacity-type") | .values' <<< "$pool")"
[ "$capacity" = '["on-demand"]' ] && pass "launches on-demand only" || fail "capacity types: $capacity"
cpu="$(yq '.spec.limits.cpu' <<< "$pool")"
[ -n "$cpu" ] && [ "$cpu" != null ] && pass "has a cap on total CPU ($cpu)" || fail "no CPU limit"
[ "$(yq '.spec.disruption.consolidationPolicy' <<< "$pool")" = WhenEmptyOrUnderutilized ] && pass "removes nodes that are empty or underused" || fail "no consolidation"

echo "names that must agree"
profile="$(yq '.spec.instanceProfile' <<< "$class")"
[ "$profile" = testcluster-karpenter-node ] && pass "the instance profile is <cluster>-karpenter-node" || fail "instance profile: $profile"
grep -q 'node_iam_role_name *= "${var.cluster_name}-karpenter-node"' infra/terraform/karpenter.tf && pass "Terraform makes a profile with that name" || fail "infra/terraform/karpenter.tf names the node role differently"
grep -q 'iam_role_name *= "${var.cluster_name}-karpenter-controller"' infra/terraform/karpenter.tf && grep -q 'controller_role="$CLUSTER-karpenter-controller"' scripts/delete-karpenter-nodes.sh && pass "the destroy script finds the controller role" || fail "controller role name differs between Terraform and the destroy script"
grep -q 'service_account *= "karpenter"' infra/terraform/karpenter.tf && grep -q 'name: karpenter$' gitops/root/templates/karpenter.yaml && pass "the service account matches the Pod Identity association" || fail "service account differs between Terraform and the Application"

echo
[ "$failures" = 0 ] && echo "The Karpenter configuration is consistent." || { echo "$failures check(s) failed."; exit 1; }
