#!/usr/bin/env bash
# Restore drill for the shared RDS server, on a running EKS cluster with the
# production profile (the study profile keeps no backups):
#   1. writes a marker row to the server
#   2. waits until RDS can restore to a point after it
#   3. restores the server to a new instance at that point, and times it
#   4. checks the copy has the marker and the same databases, from inside the cluster
#   5. deletes the copy and the marker, whatever happened
# Usage: scripts/rds-restore-drill.sh [kube context]
set -uo pipefail

CONTEXT="${1:-$(kubectl config current-context)}"
SOURCE="${SOURCE:-idp-shared-postgres}"
DRILL="$SOURCE-drill-$(date +%s)"
k() { kubectl --context "$CONTEXT" "$@"; }

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

# Runs SQL in a throwaway pod with the admin login provider-sql uses,
# against host $1 (empty for the source server). Prints psql's output.
pc="$(k get clusterproviderconfigs.postgresql.sql.m.crossplane.io shared-postgres -o json)"
secret_ns="$(jq -r .spec.credentials.connectionSecretRef.namespace <<<"$pc")"
secret="$(jq -r .spec.credentials.connectionSecretRef.name <<<"$pc")"
host_key="$(jq -r '.spec.credentials.secretKeyMapping.endpoint // "endpoint"' <<<"$pc")"
run_sql() {
  local host="$1" sql="$2" pod="drill-psql-$RANDOM"
  jq -n --arg pod "$pod" --arg s "$secret" --arg h "$host_key" --arg host "$host" --arg sql "$sql" '{
    apiVersion: "v1", kind: "Pod", metadata: {name: $pod},
    spec: {restartPolicy: "Never", containers: [{name: "psql", image: "postgres:18-alpine",
      env: [
        (if $host == "" then {name: "PGHOST", valueFrom: {secretKeyRef: {name: $s, key: $h}}}
         else {name: "PGHOST", value: $host} end),
        {name: "PGPORT", valueFrom: {secretKeyRef: {name: $s, key: "port"}}},
        {name: "PGUSER", valueFrom: {secretKeyRef: {name: $s, key: "username"}}},
        {name: "PGPASSWORD", valueFrom: {secretKeyRef: {name: $s, key: "password"}}},
        {name: "PGDATABASE", value: "postgres"}, {name: "PGSSLMODE", value: "require"},
        {name: "SQL", value: $sql}],
      command: ["sh", "-c", "psql -X -At -v ON_ERROR_STOP=1 -c \"$SQL\" 2>&1"]}]}}' |
    k apply -n "$secret_ns" -f - > /dev/null
  for _ in $(seq 1 60); do
    case "$(k get pod -n "$secret_ns" "$pod" -o jsonpath='{.status.phase}')" in Succeeded | Failed) break ;; esac
    sleep 2
  done
  k logs -n "$secret_ns" "$pod"
  k delete pod -n "$secret_ns" "$pod" --wait=false > /dev/null
}

cleanup() {
  echo "Cleaning up"
  run_sql "" "DROP TABLE IF EXISTS restore_drill" > /dev/null
  if aws rds describe-db-instances --db-instance-identifier "$DRILL" > /dev/null 2>&1; then
    aws rds delete-db-instance --db-instance-identifier "$DRILL" \
      --skip-final-snapshot --delete-automated-backups > /dev/null &&
      echo "  Deleting $DRILL (it finishes in the background)"
  fi
}
trap cleanup EXIT

echo "Cluster: $CONTEXT, server: $SOURCE"
src="$(aws rds describe-db-instances --db-instance-identifier "$SOURCE" --query 'DBInstances[0]' --output json)" ||
  { echo "No RDS instance $SOURCE."; exit 1; }
if [ "$(jq -r .BackupRetentionPeriod <<<"$src")" = 0 ]; then
  echo "$SOURCE keeps no backups. Run the session with the production profile."
  exit 1
fi

echo "1. Writing a marker row"
marker="$(run_sql "" "CREATE TABLE IF NOT EXISTS restore_drill (at timestamptz); INSERT INTO restore_drill VALUES (now()) RETURNING to_char(at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')" | tail -n 1)"
databases="$(run_sql "" "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database WHERE NOT datistemplate")"
if [ -n "$marker" ]; then pass "marker written at $marker, databases: $databases"; else fail "couldn't write the marker"; exit 1; fi

echo "2. Waiting until RDS can restore to after the marker (it lags up to about 5 minutes)"
for _ in $(seq 1 40); do
  latest="$(aws rds describe-db-instances --db-instance-identifier "$SOURCE" \
    --query 'DBInstances[0].LatestRestorableTime' --output text | cut -c1-19)Z"
  # It's "None" until the first backup exists, which would compare as later.
  [[ $latest =~ ^[0-9] && "$latest" > "$marker" ]] && break
  sleep 30
done
if [[ $latest =~ ^[0-9] && "$latest" > "$marker" ]]; then
  pass "latest restorable time $latest"
else
  fail "latest restorable time stayed at $latest"
  exit 1
fi

echo "3. Restoring $SOURCE to $DRILL at $latest"
start=$SECONDS
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$SOURCE" --target-db-instance-identifier "$DRILL" \
  --restore-time "$latest" \
  --db-instance-class "$(jq -r .DBInstanceClass <<<"$src")" \
  --db-subnet-group-name "$(jq -r .DBSubnetGroup.DBSubnetGroupName <<<"$src")" \
  --vpc-security-group-ids "$(jq -r '.VpcSecurityGroups[0].VpcSecurityGroupId' <<<"$src")" \
  --no-multi-az --no-publicly-accessible --backup-retention-period 0 > /dev/null || { fail "restore request failed"; exit 1; }
aws rds wait db-instance-available --db-instance-identifier "$DRILL" || { fail "$DRILL never became available"; exit 1; }
host="$(aws rds describe-db-instances --db-instance-identifier "$DRILL" --query 'DBInstances[0].Endpoint.Address' --output text)"
pass "restored and available in $(((SECONDS - start) / 60))m$(((SECONDS - start) % 60))s"

echo "4. Checking the copy from inside the cluster"
restored_marker="$(run_sql "$host" "SELECT to_char(max(at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM restore_drill" | tail -n 1)"
if [ "$restored_marker" = "$marker" ]; then pass "marker row is there ($restored_marker)"; else fail "marker row missing: got '$restored_marker'"; fi
restored_dbs="$(run_sql "$host" "SELECT string_agg(datname, ',' ORDER BY datname) FROM pg_database WHERE NOT datistemplate")"
if [ "$restored_dbs" = "$databases" ]; then pass "same databases: $restored_dbs"; else fail "databases differ: $restored_dbs"; fi

echo
if [ "$failures" = 0 ]; then echo "Restore drill passed."; else echo "$failures check(s) failed."; exit 1; fi
