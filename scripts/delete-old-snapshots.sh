#!/usr/bin/env bash
# Deletes the EBS snapshots CloudNativePG took for in-cluster databases once
# they're older than the backup retention. Destroying the cluster leaves its
# snapshots behind on purpose, so they can still be restored from, and this
# keeps them from piling up. Only touches snapshots tagged by the
# ebs-snapshots VolumeSnapshotClass. Set DRY_RUN=1 to only list them.
set -euo pipefail

DAYS="${1:-7}"
cutoff="$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-"$DAYS"d +%Y-%m-%dT%H:%M:%S)"

snapshots="$(aws ec2 describe-snapshots --owner-ids self \
  --filters Name=tag:idp/backup,Values=cloudnative-pg \
  --query "Snapshots[?StartTime<'$cutoff'].SnapshotId" --output text | tr '\t' '\n' | sed '/^$/d')"
if [ -z "$snapshots" ]; then
  echo "No database snapshots older than $DAYS days."
  exit 0
fi
while read -r id; do echo "  $id"; done <<<"$snapshots"
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "Dry run: would delete $(wc -l <<<"$snapshots" | tr -d ' ') snapshots."
  exit 0
fi
while read -r id; do aws ec2 delete-snapshot --snapshot-id "$id"; done <<<"$snapshots"
echo "Deleted $(wc -l <<<"$snapshots" | tr -d ' ') database snapshots older than $DAYS days."
