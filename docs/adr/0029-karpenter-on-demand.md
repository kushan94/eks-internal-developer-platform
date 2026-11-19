# ADR 0029: Karpenter for node autoscaling, on-demand only

**Status:** Accepted (2026-11-19). Verified on a production-profile cluster: scale up, scale down and the destroy sweep all worked. Two problems found on the way are fixed (see Consequences).

## Context
The node group has a fixed size: two nodes, or three zones' worth on the production profile, and it only grows when someone changes Terraform. [ADR 0022](0022-autoscaling.md) scales pods with demand, but pods beyond what fits stay Pending. A node autoscaler closes that gap, and also removes nodes that are empty or mostly idle.

Karpenter was thought to be blocked by the account's organization policy. That was a false result from the policy simulator (see the update in [ADR 0003](0003-local-first-ephemeral-eks.md)). On 2026-11-19 I tested what the account allows:

- **Permissions:** the simulator allowed every action Karpenter needs, and denied the known-blocked ones (the OIDC provider, `RequestSpotInstances`) as a control.
- **Instance types:** dry-run `RunInstances` succeeded on-demand for m7i-flex, t3, m7i, m6i and c7i. The README's claim that only Free Tier-eligible types are allowed no longer holds. It probably ended with the Paid plan; I haven't checked.
- **Spot is denied.** A real `CreateFleet` for Spot failed with `ec2:RunInstances on instance/*` and "an explicit deny in a service control policy" (`p-8k0wbze7`), although the `CreateFleet` dry-run had said it would succeed. A dry-run does not show it, because Karpenter's launch is authorized on the instance itself. The test launch template was deleted, and no instance was created.

## Decision
- **Karpenter 1.15.1** (it supports Kubernetes 1.36 from 1.13), installed by Argo CD from its OCI chart into `kube-system`, with a controller role through Pod Identity, like the Crossplane providers.
- **One NodePool, on-demand only,** amd64, categories c, m and r, generation above 5, sizes large to 2xlarge. The NodePool's limit is 8 vCPU and 32 GiB in total, about four m7i.large nodes or $0.40 an hour, so a mistake can't run up a bill. Nodes that are empty or underused are consolidated after two minutes.
- **Terraform owns the node role and its instance profile.** The EC2NodeClass names the profile, so Karpenter needs no IAM write permissions, and nothing IAM-shaped is created outside Terraform.
- **The managed node group stays.** It runs Karpenter and the system pods, so Karpenter never has to launch the node it runs on.
- **No interruption queue,** because there is no Spot to interrupt.
- **The destroy removes what Karpenter launched.** `scripts/delete-karpenter-nodes.sh` first removes the controller's inline policy, so it can't launch replacements, then terminates the instances carrying its `karpenter.sh/nodepool` tag in the cluster's VPC, then deletes its launch templates. Without it the instances' network interfaces would block deleting the VPC.

## Alternatives considered
- **EKS Auto Mode:** managed by AWS, but it takes over the node group, add-ons and load balancing, which this platform already configures. Untested here.
- **Cluster Autoscaler:** works with the existing node group, but can only scale groups of one instance type, and picks nodes less carefully.
- **A larger fixed node group:** simplest, and what the platform does now, but it pays for idle capacity all night.

## Consequences
- **Spot is out,** so the savings Karpenter is known for (Spot nodes) are unavailable. What remains is fitting nodes to pods, and removing idle nodes.
- **The nodes it launches use `al2023@latest`,** so a node launched later may have a newer image than one launched earlier. Pin a version to control when that happens.
- **Verified on a cluster (2026-11-19):** the OCI chart pulled with no registry entry in Argo CD; the controller, EC2NodeClass and NodePool went Ready. Three pods requesting 1 vCPU each, with no room on the three nodes, made Karpenter launch three `c7i-flex.large` on-demand nodes: launched in 2 to 3 seconds, registered in about 15 and initialized in about 30 from creation. After the pods were deleted, the nodes were consolidated away about 3 minutes later and the instances terminated. A destroy with a Karpenter node still running terminated it and finished (122 resources) with nothing left blocking the VPC.
- **It picks `-flex` types.** For 1 vCPU pods it chose `c7i-flex.large`, the cheapest that fits. The account allows them.
- **Two things went wrong around it, both fixed.** (1) cert-manager and the load balancer controller deadlocked (the controller's Service webhook rejected cert-manager's own Service, and the controller can't run without cert-manager's certificate); the cert-manager namespace is now exempt from that webhook, and a fresh build then needed no repair. (2) The destroy sweep looked for launch templates by a tag from Karpenter's documentation that Karpenter doesn't set; it uses `eks:eks-cluster-name` and `karpenter.sh/nodepool` now. Karpenter deletes its launch templates itself within minutes, so the sweep rarely finds one; I confirmed the tags once, from a live template, and not the sweep's launch template step against a live one.
- **Not tested:** how Karpenter behaves under a real workload (disruption of pods with local state, node expiry), and with the node group at its minimum under the study profile.
