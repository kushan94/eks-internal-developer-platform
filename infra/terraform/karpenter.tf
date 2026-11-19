# Karpenter adds nodes when pods can't be scheduled and removes them when they
# aren't needed. The node group keeps a fixed base of nodes for it and the
# system pods; the NodePool in platform/karpenter decides what it may launch.
#
# On-demand only. The organization's policy denies launching Spot instances
# (ec2:RunInstances on instance/* with an explicit deny, tested 2026-11-19),
# so there is no interruption queue either.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.29"
  count   = var.enable_eks ? 1 : 0

  cluster_name = module.eks[0].cluster_name

  # Names are fixed, because gitops/root/templates/karpenter.yaml refers to the
  # instance profile, and scripts/delete-karpenter-nodes.sh to the controller role.
  iam_role_name            = "${var.cluster_name}-karpenter-controller"
  iam_role_use_name_prefix = false
  node_iam_role_name       = "${var.cluster_name}-karpenter-node"

  node_iam_role_use_name_prefix = false

  # Terraform owns the instance profile, so Karpenter doesn't need permission to
  # create IAM objects, and nothing it makes outside Terraform blocks the destroy.
  create_instance_profile = true

  # An inline policy, so the destroy can remove the controller's permissions
  # first, which stops it launching nodes while the cluster is torn down.
  enable_inline_policy = true

  # No Spot, so nothing to be interrupted.
  enable_spot_termination = false

  # The Pod Identity association is part of the module: kube-system/karpenter.
  namespace       = "kube-system"
  service_account = "karpenter"
}
