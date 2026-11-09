#!/usr/bin/env bash
# Deletes the Secrets Manager secrets that Crossplane created for WebService
# databases on ECS (idp/workloads/...), after removing Crossplane's AWS
# permissions so it can't recreate them. Run when destroying the cluster:
# Crossplane can't clean them up once the cluster is gone, and a leftover
# secret blocks creating one with the same name next session.
# Set DRY_RUN=1 to only list them.
set -euo pipefail

CLUSTER="${1:?usage: $0 <cluster name>}"

crossplane_role="$CLUSTER-crossplane-aws"
if [ "${DRY_RUN:-0}" != 1 ] && aws iam get-role-policy --role-name "$crossplane_role" --policy-name webservice-ecs-runtime > /dev/null 2>&1; then
  echo "Removing Crossplane's AWS permissions"
  aws iam delete-role-policy --role-name "$crossplane_role" --policy-name webservice-ecs-runtime
  # IAM changes take a few seconds to apply everywhere.
  sleep 15
fi

secrets="$(aws secretsmanager list-secrets --include-planned-deletion \
  --filters Key=name,Values=idp/workloads/ --query 'SecretList[].Name' --output text | tr '\t' '\n' | sed '/^$/d')"
if [ -z "$secrets" ]; then
  echo "No workload secrets."
  exit 0
fi
while read -r name; do echo "  $name"; done <<<"$secrets"
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "Dry run: would delete $(wc -l <<<"$secrets" | tr -d ' ') secrets."
  exit 0
fi
while read -r name; do
  aws secretsmanager delete-secret --secret-id "$name" --force-delete-without-recovery > /dev/null
done <<<"$secrets"
echo "Deleted $(wc -l <<<"$secrets" | tr -d ' ') workload secrets."
