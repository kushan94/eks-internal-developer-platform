#!/usr/bin/env bash
# Deletes the load balancers, target groups and security groups that the AWS
# Load Balancer Controller created for a cluster, found by its
# elbv2.k8s.aws/cluster tag. Run before destroying the cluster's VPC.
set -euo pipefail

CLUSTER="${1:?usage: $0 <cluster name>}"

# Stop the controller first. If its pod restarts while the cluster is being
# destroyed, it would otherwise recreate the load balancer and block deleting
# the VPC. Terraform tolerates the policy being gone when it destroys the role.
controller_role="$CLUSTER-aws-load-balancer-controller"
if aws iam get-role-policy --role-name "$controller_role" --policy-name aws-load-balancer-controller > /dev/null 2>&1; then
  echo "Removing the load balancer controller's AWS permissions"
  aws iam delete-role-policy --role-name "$controller_role" --policy-name aws-load-balancer-controller
  # IAM changes take a few seconds to apply everywhere.
  sleep 15
fi

tagged() {
  aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" \
    --resource-type-filters "$1" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
}

load_balancers="$(tagged elasticloadbalancing:loadbalancer)"
for arn in $load_balancers; do
  echo "Deleting load balancer ${arn##*/loadbalancer/}"
  aws elbv2 delete-load-balancer --load-balancer-arn "$arn"
done
if [ -n "$load_balancers" ]; then
  # shellcheck disable=SC2086
  aws elbv2 wait load-balancers-deleted --load-balancer-arns $load_balancers
fi

for arn in $(tagged elasticloadbalancing:targetgroup); do
  echo "Deleting target group ${arn##*/targetgroup/}"
  aws elbv2 delete-target-group --target-group-arn "$arn" || true
done

for arn in $(tagged ec2:security-group); do
  group="${arn##*/}"
  # Other groups, such as the nodes', may allow traffic from this one.
  for referrer in $(aws ec2 describe-security-groups --filters "Name=ip-permission.group-id,Values=$group" --query 'SecurityGroups[].GroupId' --output text); do
    rules="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$referrer" \
      --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='$group' && !IsEgress].SecurityGroupRuleId" --output text)"
    if [ -n "$rules" ]; then
      # shellcheck disable=SC2086
      aws ec2 revoke-security-group-ingress --group-id "$referrer" --security-group-rule-ids $rules > /dev/null
    fi
  done
  echo "Deleting security group $group"
  # The load balancer's network interfaces can take a few minutes to go away.
  for attempt in $(seq 1 30); do
    aws ec2 delete-security-group --group-id "$group" 2>/dev/null && break
    [ "$attempt" = 30 ] && { echo "Could not delete $group" >&2; exit 1; }
    sleep 10
  done
done

echo "Load balancer cleanup for $CLUSTER is done."
