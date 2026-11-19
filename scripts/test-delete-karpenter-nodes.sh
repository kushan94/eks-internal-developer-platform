#!/usr/bin/env bash
# Tests delete-karpenter-nodes.sh with a fake aws command and sleep, so nothing
# is touched and nothing waits. The fake holds two Karpenter nodes in the
# cluster's VPC, one node group instance Karpenter did not launch, and one
# launch template.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
echo s >> "$SLEEPS"
FAKE
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1 $2" in
  "iam list-role-policies")
    [ -n "${NO_ROLE:-}" ] && { echo "NoSuchEntity" >&2; exit 254; }
    echo "KarpenterController-2026111812345" ;;
  "ec2 describe-vpcs") [ -n "${NO_VPC:-}" ] && echo None || echo vpc-123 ;;
  "ec2 describe-instances")
    # Only the instances carrying Karpenter's tag, in the cluster's VPC, may be asked for.
    case "$*" in
      *vpc-id,Values=vpc-123*tag-key,Values=karpenter.sh/nodepool*) echo "i-karp1 i-karp2" ;;
    esac ;;
  "ec2 describe-launch-templates")
    # Both tags, as Karpenter really sets them: the cluster's name and its node pool.
    case "$*" in *tag:eks:eks-cluster-name,Values=idp*tag-key,Values=karpenter.sh/nodepool*) echo "lt-abc" ;; esac ;;
esac
FAKE
chmod +x "$work/bin/aws" "$work/bin/sleep"

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
run() { CALLS="$work/calls" SLEEPS="$work/sleeps" PATH="$work/bin:$PATH" "$@"; }
reset() { : > "$work/calls"; : > "$work/sleeps"; }
called() { grep -q -- "$1" "$work/calls"; }

echo "a cluster with Karpenter's nodes"
reset
run scripts/delete-karpenter-nodes.sh idp > "$work/out" 2>&1; code=$?
[ "$code" = 0 ] && pass "the script succeeds" || fail "exit $code: $(cat "$work/out")"
called "iam delete-role-policy --role-name idp-karpenter-controller --policy-name KarpenterController-2026111812345" && pass "the controller's permissions go first" || fail "the controller's policy was not removed"
first_delete="$(grep -n "delete-role-policy" "$work/calls" | head -1 | cut -d: -f1)"
first_terminate="$(grep -n "terminate-instances" "$work/calls" | head -1 | cut -d: -f1)"
[ -n "$first_delete" ] && [ -n "$first_terminate" ] && [ "$first_delete" -lt "$first_terminate" ] && pass "before any node is terminated" || fail "the order is wrong (policy $first_delete, terminate $first_terminate)"
called "terminate-instances --instance-ids i-karp1 i-karp2" && pass "both Karpenter nodes are terminated" || fail "terminate calls: $(grep terminate "$work/calls")"
called "wait instance-terminated --instance-ids i-karp1 i-karp2" && pass "and waited for them" || fail "did not wait for the nodes to go"
called "delete-launch-template --launch-template-id lt-abc" && pass "the launch template is deleted" || fail "the launch template was left"

echo "the instances are chosen by Karpenter's tag, in this cluster's VPC"
called "describe-instances --filters Name=vpc-id,Values=vpc-123 Name=tag-key,Values=karpenter.sh/nodepool" && pass "the filter names the VPC and the tag" || fail "filter: $(grep describe-instances "$work/calls")"
called "terminate-instances.*i-node" && fail "a node group instance would be terminated" || pass "nothing else is terminated"

echo "a cluster that is already gone"
reset
NO_ROLE=1 NO_VPC=1 run scripts/delete-karpenter-nodes.sh idp > "$work/out" 2>&1; code=$?
[ "$code" = 0 ] && pass "the script still succeeds" || fail "exit $code: $(cat "$work/out")"
called "terminate-instances" && fail "it terminated instances with no VPC" || pass "and terminates nothing"

echo
[ "$failures" = 0 ] && echo "Karpenter's nodes are removed after its permissions, and only they are." || { echo "$failures check(s) failed."; exit 1; }
