#!/usr/bin/env bash
# Deletes the EBS volumes a cluster's PersistentVolumeClaims left behind once
# the cluster is gone. Kubernetes keeps a StatefulSet's claims when the
# StatefulSet is deleted, so Loki's 5 GiB volume survived every destroy and a
# new one was created each session. Only touches volumes tagged as owned by
# this cluster that aren't attached to anything, and refuses to run while the
# cluster exists, because then a volume may be in use.
# Usage: scripts/delete-k8s-volumes.sh <cluster name>    Set DRY_RUN=1 to only list them.
set -euo pipefail

cluster="${1:?usage: delete-k8s-volumes.sh <cluster name>}"

# A volume that looks unattached may belong to a pod that is starting.
if aws eks describe-cluster --name "$cluster" > /dev/null 2>&1; then
  echo "The cluster $cluster still exists, so its volumes may be in use. Run this after it is destroyed." >&2
  exit 1
fi

volumes="$(aws ec2 describe-volumes \
  --filters "Name=tag:kubernetes.io/cluster/$cluster,Values=owned" "Name=status,Values=available" \
  --query 'Volumes[].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' --output text | sed '/^$/d')"
if [ -z "$volumes" ]; then
  echo "No leftover volumes from the cluster $cluster."
  exit 0
fi
while read -r id size pvc; do echo "  $id  ${size} GiB  (for the claim ${pvc:-unknown})"; done <<<"$volumes"
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "Dry run: would delete $(wc -l <<<"$volumes" | tr -d ' ') volume(s)."
  exit 0
fi
while read -r id _; do aws ec2 delete-volume --volume-id "$id"; done <<<"$volumes"
echo "Deleted $(wc -l <<<"$volumes" | tr -d ' ') leftover volume(s) from the cluster $cluster."
