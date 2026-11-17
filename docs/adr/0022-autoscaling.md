# ADR 0022: Autoscale services on CPU with a HorizontalPodAutoscaler

**Status:** Accepted (2026-11-13)

## Context
Every service ran a fixed number of replicas: too many when idle, too few under load. Production platforms scale services with demand. Node autoscaling with Karpenter isn't set up yet (it was thought to be blocked by the account's organization policy, which turned out to be a false result: see the update in [ADR 0003](0003-local-first-ephemeral-eks.md)), but pod autoscaling only needs metrics-server, which every cluster already runs.

## Decision
- **An optional `spec.autoscaling` on `WebService`:** `minReplicas`, `maxReplicas` (up to 50) and `targetCPUUtilization` (default 70%, of each pod's CPU request). The XRD refuses `maxReplicas` below `minReplicas` with a CEL rule.
- **The composition adds an `autoscaling/v2` HorizontalPodAutoscaler**, and leaves `replicas` off the Deployment. Otherwise Crossplane would reset the count the autoscaler chose on every reconcile.
- **`minReplicas` takes over where `replicas` counted:**
  - The service is ready once it has its minimum.
  - It gets a PodDisruptionBudget when the minimum is above 1.
  - Kyverno's `prod-replicas` policy checks the minimum in prod. A prod service with `replicas: 3` but `minReplicas: 1` is refused, because it can drop to one replica.
- **Kubernetes runtime only.** ECS autoscaling uses a separate AWS API (Application Auto Scaling), so an ECS service with `autoscaling` fails with a clear message, and the Backstage form hides the option for ECS.
- **The Backstage template has an "Autoscale on CPU" option.** With environments, the maximum is shared in `base`, and each environment sets its own minimum: 1 in dev and staging, and at least 2 in prod.
- **Testing:**
  - `make test` renders a service with autoscaling and checks the Deployment has no replica count and the HPA has the right bounds. It also checks that the XRD refuses max below min, and that an ECS render fails.
  - `make test-template` covers the template's autoscaling variant.
  - On a throwaway kind cluster with metrics-server, the rendered Deployment and HPA idled at 2 replicas, then under load reached 89% CPU and scaled to 5 within a minute.

## Alternatives considered
- **KEDA:** scales on queues, request rates and schedules, and down to zero. More capable, but another operator. CPU covers the common case, and KEDA builds on the same HPA when needed.
- **Scaling on request rate:** needs per-service request metrics, which only services that expose them have.

## Consequences
- **Scaling up needs room on the nodes.** Without Karpenter, the node group only grows to its maximum when someone changes Terraform. Pods beyond what fits stay Pending.
- **CPU-based scaling only fits CPU-bound services.** One that waits on its database stays at its minimum.
- **Scale-down is deliberately slow.** The HPA waits 5 minutes by default before removing replicas.
