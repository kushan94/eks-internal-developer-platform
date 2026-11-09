#!/usr/bin/env bash
# End-to-end test of WebService databases on a running cluster (kind or EKS):
#   1. creates services with a managed and an in-cluster database
#   2. logs in to each with the exact environment the service's container gets
#   3. checks one service's login can't open another service's database
#   4. deletes the services and checks the shared server has nothing left
# Usage: scripts/test-databases.sh [kube context]
set -uo pipefail

CONTEXT="${1:-$(kubectl config current-context)}"
NS=db-test
k() { kubectl --context "$CONTEXT" "$@"; }

failures=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

cleanup() { k delete namespace "$NS" --ignore-not-found --wait=false > /dev/null; }
trap cleanup EXIT

# Runs SQL in a throwaway pod in namespace $1, with env JSON $2. Prints psql's output.
run_sql() {
  local ns="$1" env="$2" sql="$3" pod="psql-$RANDOM"
  jq -n --arg pod "$pod" --argjson env "$env" --arg sql "$sql" '{
    apiVersion: "v1", kind: "Pod", metadata: {name: $pod},
    spec: {restartPolicy: "Never", containers: [{name: "psql", image: "postgres:18-alpine",
      env: ($env + [{name: "SQL", value: $sql}]),
      command: ["sh", "-c", "psql -X -At -v ON_ERROR_STOP=1 -c \"$SQL\" 2>&1"]}]}}' |
    k apply -n "$ns" -f - > /dev/null
  for _ in $(seq 1 60); do
    case "$(k get pod -n "$ns" "$pod" -o jsonpath='{.status.phase}')" in Succeeded | Failed) break ;; esac
    sleep 2
  done
  k logs -n "$ns" "$pod"
  k delete pod -n "$ns" "$pod" --wait=false > /dev/null
}

# The env a service's container gets, optionally pointed at another database.
service_env() {
  k get deploy -n "$NS" "$1" -o json |
    jq -c --arg db "${2:-}" '.spec.template.spec.containers[0].env
      | if $db != "" then map(if .name == "PGDATABASE" then .value = $db else . end) else . end'
}

echo "Cluster: $CONTEXT"
echo "1. Creating services with databases"
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - > /dev/null
for svc in alpha:managed beta:managed gamma:in-cluster; do
  cat <<YAML | k apply -f - > /dev/null
apiVersion: platform.example.org/v1alpha1
kind: WebService
metadata:
  name: ${svc%%:*}
  namespace: $NS
spec:
  image: nginxinc/nginx-unprivileged:1.29-alpine
  port: 8080
  replicas: 1
  database:
    class: ${svc##*:}
YAML
done
start=$SECONDS
if k wait webservice -n "$NS" --all --for=condition=Ready --timeout=10m > /dev/null; then
  pass "all services Ready in $((SECONDS - start))s"
else
  fail "services not Ready after 10 minutes"
  k get webservice,managed -n "$NS"
  exit 1
fi

echo "2. Logging in with each service's environment"
for svc in alpha:managed gamma:in-cluster; do
  name="${svc%%:*}"
  out="$(run_sql "$NS" "$(service_env "$name")" \
    "CREATE TABLE t (x int); INSERT INTO t VALUES (1); SELECT count(*) || ' row, ssl=' || (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()) FROM t")"
  if grep -q '^1 row, ssl=true$' <<<"$out"; then
    pass "$name (${svc##*:}): created, wrote and read a table over TLS"
  else
    fail "$name (${svc##*:}): $out"
  fi
done

echo "3. Checking isolation"
other_db="$(k get webservice -n "$NS" beta -o jsonpath='{.status.database.name}')"
out="$(run_sql "$NS" "$(service_env alpha "$other_db")" "SELECT 1")"
if grep -q 'User does not have CONNECT privilege' <<<"$out"; then
  pass "alpha's login can't open beta's database"
else
  fail "alpha's login reached beta's database: $out"
fi

echo "4. Deleting the services"
managed_dbs="$(k get webservice -n "$NS" -o json | jq -r '.items[] | select(.spec.database.class == "managed") | .status.database.name')"
k delete webservice -n "$NS" --all --wait=false > /dev/null
start=$SECONDS
while [ -n "$(k get managed,cluster.postgresql.cnpg.io -n "$NS" --no-headers 2>/dev/null)" ]; do
  if [ $((SECONDS - start)) -gt 300 ]; then fail "resources left after 5 minutes"; k get managed -n "$NS"; break; fi
  sleep 5
done
[ $((SECONDS - start)) -le 300 ] && pass "all database resources deleted in $((SECONDS - start))s"

# Ask the shared server directly, with the admin login provider-sql uses.
pc="$(k get clusterproviderconfigs.postgresql.sql.m.crossplane.io shared-postgres -o json)"
secret_ns="$(jq -r .spec.credentials.connectionSecretRef.namespace <<<"$pc")"
secret="$(jq -r .spec.credentials.connectionSecretRef.name <<<"$pc")"
host_key="$(jq -r '.spec.credentials.secretKeyMapping.endpoint // "endpoint"' <<<"$pc")"
admin_env="$(jq -nc --arg s "$secret" --arg h "$host_key" '[
  {name: "PGHOST", valueFrom: {secretKeyRef: {name: $s, key: $h}}},
  {name: "PGPORT", valueFrom: {secretKeyRef: {name: $s, key: "port"}}},
  {name: "PGUSER", valueFrom: {secretKeyRef: {name: $s, key: "username"}}},
  {name: "PGPASSWORD", valueFrom: {secretKeyRef: {name: $s, key: "password"}}},
  {name: "PGDATABASE", value: "postgres"}, {name: "PGSSLMODE", value: "require"}]')"
names="$(paste -sd, - <<<"$managed_dbs" | sed "s/[^,]*/'&'/g")"
left="$(run_sql "$secret_ns" "$admin_env" \
  "SELECT (SELECT count(*) FROM pg_database WHERE datname IN ($names)) + (SELECT count(*) FROM pg_roles WHERE rolname IN ($names))")"
if [ "$left" = 0 ]; then
  pass "shared server has no databases or logins left for $(tr '\n' ' ' <<<"$managed_dbs")"
else
  fail "shared server still has $left databases or logins: $left"
fi

echo
if [ "$failures" = 0 ]; then echo "All database checks passed."; else echo "$failures check(s) failed."; exit 1; fi
