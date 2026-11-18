#!/usr/bin/env bash
# Tests delete-k8s-volumes.sh with a fake aws command, so nothing is touched.
# The fake records every call and answers from canned output.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1 $2" in
  "eks describe-cluster") [ "${CLUSTER_EXISTS:-0}" = 1 ] && echo '{}' || { echo "ResourceNotFoundException" >&2; exit 254; } ;;
  "ec2 describe-volumes") printf '%b' "${VOLUMES:-}" ;;
  "ec2 delete-volume") : ;;
esac
FAKE
chmod +x "$work/bin/aws"

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
run() { CALLS="$work/calls" PATH="$work/bin:$PATH" "$@"; }
: > "$work/calls"

echo "with two leftover volumes, for real"
out="$(CLUSTER_EXISTS=0 VOLUMES='vol-aaa\t5\tstorage-loki-0\nvol-bbb\t20\tdata-db-1\n' run scripts/delete-k8s-volumes.sh idp 2>&1)"
grep -q "vol-aaa" <<<"$out" && grep -q "vol-bbb" <<<"$out" && pass "lists both volumes with their claims" || fail "output: $out"
grep -q "ec2 delete-volume --volume-id vol-aaa" "$work/calls" && grep -q "ec2 delete-volume --volume-id vol-bbb" "$work/calls" && pass "deletes each one" || fail "calls: $(cat "$work/calls")"
grep -qE "Name=tag:kubernetes.io/cluster/idp,Values=owned( |$)" "$work/calls" && grep -qE "Name=status,Values=available( |$)" "$work/calls" && pass "only asks for volumes owned by the cluster, and not attached" || fail "the filters are wrong: $(grep describe-volumes "$work/calls")"

echo "a dry run"
: > "$work/calls"
out="$(DRY_RUN=1 CLUSTER_EXISTS=0 VOLUMES='vol-aaa\t5\tstorage-loki-0\n' run scripts/delete-k8s-volumes.sh idp 2>&1)"
grep -q "Dry run: would delete 1" <<<"$out" && pass "says what it would do" || fail "output: $out"
grep -q "delete-volume" "$work/calls" && fail "a dry run deleted something" || pass "deletes nothing"

echo "while the cluster still exists"
: > "$work/calls"
CLUSTER_EXISTS=1 VOLUMES='vol-aaa\t5\tx\n' run scripts/delete-k8s-volumes.sh idp > "$work/out" 2>&1; code=$?
[ "$code" = 1 ] && grep -q "still exists" "$work/out" && pass "refuses to run" || fail "exit $code: $(cat "$work/out")"
grep -qE "describe-volumes|delete-volume" "$work/calls" && fail "it looked at volumes anyway" || pass "doesn't even look at the volumes"

echo "with nothing left"
: > "$work/calls"
out="$(CLUSTER_EXISTS=0 VOLUMES='' run scripts/delete-k8s-volumes.sh idp 2>&1)"
grep -q "No leftover volumes" <<<"$out" && ! grep -q "delete-volume" "$work/calls" && pass "reports it and deletes nothing" || fail "output: $out"

echo "a missing argument"
run scripts/delete-k8s-volumes.sh > "$work/out" 2>&1 && fail "accepted no cluster name" || pass "needs a cluster name"

echo
[ "$failures" = 0 ] && echo "delete-k8s-volumes.sh does what it says." || { echo "$failures check(s) failed."; exit 1; }
