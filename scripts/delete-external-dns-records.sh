#!/usr/bin/env bash
# Deletes the DNS records that ExternalDNS created in a Route 53 zone, found by
# the owner ID in its TXT ownership records, after removing ExternalDNS's
# permissions so it can't recreate them. The owner ID is the cluster name. Run when destroying the cluster, so
# no records point at a deleted load balancer. Set DRY_RUN=1 to only list them.
set -euo pipefail

ZONE="${1:?usage: $0 <zone name> <external-dns owner id>}"
OWNER="${2:?usage: $0 <zone name> <external-dns owner id>}"

zone_id="$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE" \
  --query "HostedZones[?Name=='$ZONE.'].Id | [0]" --output text)"
if [ -z "$zone_id" ] || [ "$zone_id" = None ]; then
  echo "No hosted zone named $ZONE."
  exit 0
fi

# Stop ExternalDNS first. It syncs every minute while the cluster is being
# destroyed, so it would otherwise recreate the records deleted below.
external_dns_role="$OWNER-external-dns"
if [ "${DRY_RUN:-0}" != 1 ] && aws iam get-role-policy --role-name "$external_dns_role" --policy-name platform-zone-records > /dev/null 2>&1; then
  echo "Removing ExternalDNS's AWS permissions"
  aws iam delete-role-policy --role-name "$external_dns_role" --policy-name platform-zone-records
  # IAM changes take a few seconds to apply everywhere.
  sleep 15
fi

records="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json)"

# ExternalDNS marks each record it owns with a TXT record, named with an
# "a-" or "aaaa-" prefix, whose value names the owner.
owned_names="$(jq -r --arg owner "external-dns/owner=$OWNER" '
  .ResourceRecordSets[]
  | select(.Type == "TXT" and any(.ResourceRecords[]?.Value; contains($owner)))
  | .Name | sub("^(a|aaaa|cname)-"; "")' <<<"$records" | sort -u)"

changes="$(jq -c --arg owner "external-dns/owner=$OWNER" --argjson names "$(jq -R . <<<"$owned_names" | jq -s .)" '
  [.ResourceRecordSets[]
   | select(
       (.Type == "TXT" and any(.ResourceRecords[]?.Value; contains($owner)))
       or ((.Type == "A" or .Type == "AAAA" or .Type == "CNAME") and (.Name as $n | $names | index($n)))
     )
   | {Action: "DELETE", ResourceRecordSet: .}]' <<<"$records")"

count="$(jq length <<<"$changes")"
if [ "$count" = 0 ]; then
  echo "No ExternalDNS records owned by $OWNER in $ZONE."
  exit 0
fi
jq -r '.[].ResourceRecordSet | "  \(.Type)\t\(.Name)"' <<<"$changes"
if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "Dry run: would delete $count records."
  exit 0
fi
aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
  --change-batch "$(jq -c '{Comment: "Cluster destroyed", Changes: .}' <<<"$changes")" > /dev/null
echo "Deleted $count records owned by $OWNER from $ZONE."
