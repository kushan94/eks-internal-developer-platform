#!/usr/bin/env bash
# Tests how delete-k8s-load-balancers.sh deletes target groups, with a fake
# aws command and sleep, so nothing is touched and nothing waits. The fake
# makes the delete of one target group fail with ResourceInUse a set number
# of times first, as AWS does just after a load balancer is deleted.
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
  "iam get-role-policy") exit 254 ;;
  "resourcegroupstaggingapi get-resources")
    case "$*" in *elasticloadbalancing:targetgroup*) printf '%s\n' "arn:aws:elasticloadbalancing:r:1:targetgroup/tg-busy/1 arn:aws:elasticloadbalancing:r:1:targetgroup/tg-free/2" ;; esac ;;
  "elbv2 delete-target-group")
    case "$*" in
      *tg-busy*)
        n=$(grep -c "delete-target-group.*tg-busy" "$CALLS")
        if [ "$n" -le "${BUSY_TIMES:-0}" ]; then echo "An error occurred (ResourceInUse) when calling the DeleteTargetGroup operation" >&2; exit 254; fi ;;
      *tg-gone*) echo "TargetGroupNotFound" >&2; exit 254 ;;
    esac ;;
esac
FAKE
chmod +x "$work/bin/aws" "$work/bin/sleep"

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
run() { CALLS="$work/calls" SLEEPS="$work/sleeps" PATH="$work/bin:$PATH" "$@"; }
reset() { : > "$work/calls"; : > "$work/sleeps"; }

echo "a target group that is in use for the first two tries"
reset
BUSY_TIMES=2 run scripts/delete-k8s-load-balancers.sh idp > "$work/out" 2>&1; code=$?
[ "$code" = 0 ] && pass "the script succeeds" || fail "exit $code: $(cat "$work/out")"
[ "$(grep -c "delete-target-group.*tg-busy" "$work/calls")" = 3 ] && pass "it tried three times" || fail "calls: $(grep delete-target-group "$work/calls")"
grep -q "delete-target-group.*tg-free" "$work/calls" && pass "and went on to the next one" || fail "the next target group was skipped"

echo "a target group that stays in use"
reset
BUSY_TIMES=99 run scripts/delete-k8s-load-balancers.sh idp > "$work/out" 2>&1; code=$?
[ "$code" = 1 ] && grep -q "Could not delete target group.*tg-busy" "$work/out" && pass "the script fails and names it" || fail "exit $code: $(cat "$work/out")"
[ "$(grep -c "delete-target-group.*tg-busy" "$work/calls")" = 18 ] && pass "after 18 tries" || fail "tries: $(grep -c 'delete-target-group.*tg-busy' "$work/calls")"

echo "control: the old behaviour would have passed over it"
grep -q '|| true' scripts/delete-k8s-load-balancers.sh && fail "a delete is still ignored with || true" || pass "no delete is ignored with || true"

echo
[ "$failures" = 0 ] && echo "Target groups are retried, and a stuck one fails the script." || { echo "$failures check(s) failed."; exit 1; }
