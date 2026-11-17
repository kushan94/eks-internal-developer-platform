#!/usr/bin/env bash
# Restore drill for in-cluster databases, on a running EKS cluster with the
# production profile (the study profile and kind take no backups):
#   1. creates a service with an in-cluster database, and writes a marker row
#   2. backs the database up as EBS snapshots, and times it
#   3. restores the snapshots into a new CloudNativePG cluster, and times it
#   4. checks the restored database has the marker row
#   5. deletes the namespace, which deletes the backups and their snapshots
# Usage: scripts/cnpg-restore-drill.sh [kube context]
set -uo pipefail
source "$(dirname "$0")/drill-lib.sh"

CONTEXT="${1:-$(kubectl config current-context)}"
NS=restore-drill
k() { kubectl --context "$CONTEXT" "$@"; }

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
elapsed() { echo "$(($1 / 60))m$(($1 % 60))s"; }

# Runs SQL as postgres on the primary of CloudNativePG cluster $1.
run_sql() {
  local primary
  primary="$(k get cluster.postgresql.cnpg.io -n "$NS" "$1" -o jsonpath='{.status.currentPrimary}')"
  k exec -n "$NS" "$primary" -c postgres -- psql -X -At -v ON_ERROR_STOP=1 -d app -c "$2" 2>&1
}

# Waits until CloudNativePG cluster $1 reports a healthy state, up to 15 minutes.
wait_healthy() {
  for _ in $(seq 1 90); do
    [ "$(k get cluster.postgresql.cnpg.io -n "$NS" "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Cluster in healthy state" ] && return 0
    sleep 10
  done
  return 1
}

cleanup() { echo "Cleaning up"; k delete namespace "$NS" --ignore-not-found --wait=false > /dev/null; }
trap cleanup EXIT

echo "Cluster: $CONTEXT"
if ! k get volumesnapshotclass ebs-snapshots > /dev/null 2>&1; then
  echo "No ebs-snapshots VolumeSnapshotClass. Run this on EKS with the production profile."
  exit 1
fi

echo "1. Creating a service with an in-cluster database"
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - > /dev/null
cat <<YAML | k apply -f - > /dev/null
apiVersion: platform.example.org/v1alpha1
kind: WebService
metadata:
  name: shop
  namespace: $NS
spec:
  image: nginxinc/nginx-unprivileged:1.29-alpine
  port: 8080
  replicas: 1
  database:
    class: in-cluster
YAML
start=$SECONDS
for _ in $(seq 1 30); do k get cluster.postgresql.cnpg.io -n "$NS" shop-db > /dev/null 2>&1 && break; sleep 10; done
if wait_healthy shop-db; then
  pass "database healthy with $(k get cluster.postgresql.cnpg.io -n "$NS" shop-db -o jsonpath='{.status.readyInstances}') instances in $(elapsed $((SECONDS - start)))"
else
  fail "database not healthy after 15 minutes"
  exit 1
fi
marker="$(run_sql shop-db "CREATE TABLE restore_drill (at timestamptz); INSERT INTO restore_drill VALUES (now()) RETURNING to_char(at, 'YYYY-MM-DD HH24:MI:SS.US')" | marker_line)"
if [ -n "$marker" ]; then pass "marker written: $marker"; else fail "couldn't write the marker"; exit 1; fi

echo "2. Backing up as EBS snapshots"
start=$SECONDS
cat <<YAML | k apply -f - > /dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: shop-db-drill
  namespace: $NS
spec:
  cluster:
    name: shop-db
  method: volumeSnapshot
YAML
for _ in $(seq 1 90); do
  phase="$(k get backup.postgresql.cnpg.io -n "$NS" shop-db-drill -o jsonpath='{.status.phase}')"
  case "$phase" in completed | failed) break ;; esac
  sleep 10
done
if [ "$phase" = completed ]; then
  pass "backup completed in $(elapsed $((SECONDS - start)))"
else
  fail "backup ended as '$phase': $(k get backup.postgresql.cnpg.io -n "$NS" shop-db-drill -o jsonpath='{.status.error}')"
  exit 1
fi
snapshot="$(k get backup.postgresql.cnpg.io -n "$NS" shop-db-drill -o json |
  jq -r '.status.snapshotBackupStatus.elements[] | select(.type == "PG_DATA") | .name')"

echo "3. Restoring snapshot $snapshot into a new cluster"
start=$SECONDS
cat <<YAML | k apply -f - > /dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: shop-db-restored
  namespace: $NS
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    recovery:
      volumeSnapshots:
        storage:
          name: $snapshot
          kind: VolumeSnapshot
          apiGroup: snapshot.storage.k8s.io
YAML
if wait_healthy shop-db-restored; then
  pass "restored cluster healthy in $(elapsed $((SECONDS - start)))"
else
  fail "restored cluster not healthy after 15 minutes"
  exit 1
fi

echo "4. Checking the restored database"
restored="$(run_sql shop-db-restored "SELECT to_char(max(at), 'YYYY-MM-DD HH24:MI:SS.US') FROM restore_drill" | marker_line)"
if [ "$restored" = "$marker" ]; then pass "marker row is there ($restored)"; else fail "marker row missing: got '$restored'"; fi

echo
if [ "$failures" = 0 ]; then echo "Restore drill passed."; else echo "$failures check(s) failed."; exit 1; fi
