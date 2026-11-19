#!/usr/bin/env bash
# Deletes the EC2 instances and launch templates Karpenter created for a
# cluster. Terraform doesn't know about them, and the instances' network
# interfaces would block deleting the VPC. Run before destroying the cluster.
set -euo pipefail

CLUSTER="${1:?usage: $0 <cluster name>}"

# Stop the controller first, or it launches a new node for every pod the
# deleted nodes leave behind. Terraform tolerates the policy being gone when it
# destroys the role.
controller_role="$CLUSTER-karpenter-controller"
removed=""
for policy in $(aws iam list-role-policies --role-name "$controller_role" --query 'PolicyNames' --output text 2> /dev/null || true); do
  echo "Removing Karpenter's AWS permissions ($policy)"
  aws iam delete-role-policy --role-name "$controller_role" --policy-name "$policy"
  removed=1
done
# IAM changes take a few seconds to apply everywhere.
[ -n "$removed" ] && sleep 15

vpc="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$CLUSTER" --query 'Vpcs[0].VpcId' --output text 2> /dev/null || true)"
if [ -n "$vpc" ] && [ "$vpc" != None ]; then
  instances="$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$vpc" "Name=tag-key,Values=karpenter.sh/nodepool" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if [ -n "$instances" ]; then
    echo "Terminating Karpenter's nodes: $instances"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $instances > /dev/null
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $instances
  fi
fi

# Karpenter tags its launch templates with the cluster's name (eks:eks-cluster-name)
# and its node pool, not with karpenter.k8s.aws/cluster as its documentation suggests.
for template in $(aws ec2 describe-launch-templates \
  --filters "Name=tag:eks:eks-cluster-name,Values=$CLUSTER" "Name=tag-key,Values=karpenter.sh/nodepool" \
  --query 'LaunchTemplates[].LaunchTemplateId' --output text); do
  echo "Deleting launch template $template"
  aws ec2 delete-launch-template --launch-template-id "$template" > /dev/null
done

echo "Karpenter cleanup for $CLUSTER is done."
