# ADR 0016: A production profile for availability, and spread for every service

**Status:** Accepted (2026-11-13)

## Context
Every EKS session ran in two AZs with one NAT gateway, two nodes, single-AZ RDS instances and one replica of most platform components. That's cheap, but losing one AZ, or the NAT gateway's AZ, takes the platform down. Production platforms are expected to survive an AZ failure and routine node drains. Paying for that in every short session wastes credits, though.

## Decision
- **A Terraform variable, `profile`, with `study` (the default) and `production`.** The Infrastructure workflow has it as an input.

  | | study | production |
  |---|---|---|
  | AZs | 2 | 3 |
  | NAT gateways | 1, shared | 1 per AZ |
  | Nodes | 2 (max 3) | 3, one per AZ (max 6) |
  | RDS (Backstage and shared Postgres) | Single-AZ | Multi-AZ |
  | Kyverno admission controllers | 1 | 3 |
  | Crossplane and its RBAC manager | 1 each | 2 each |
  | Backstage | 1 | 2 |
  | In-cluster databases (CloudNativePG) | 1 instance | 3, spread across zones |

- **The profile reaches the cluster two ways.**
  - Terraform outputs `high_availability`, and the Cluster workflow passes it to the root application, which sets the replica counts.
  - Terraform also adds `highAvailability` to the `aws-platform` EnvironmentConfig, which the `WebService` composition reads for database instances.
- **Every `WebService` on Kubernetes gets two things in both profiles:**
  - Its pods spread across zones, then nodes. The constraints are soft (`ScheduleAnyway`), so they don't block scheduling on kind's single zone. `matchLabelKeys: [pod-template-hash]` makes them apply per rollout.
  - With more than one replica, a PodDisruptionBudget allowing one pod down at a time, so node drains and upgrades never take a service offline.
- **Subnets are computed from the AZ count** with `cidrsubnet`. The study profile's subnets are the same as before.

## Alternatives considered
- **Always run the production shape:** simplest, but about 60% more per hour for sessions that don't test availability.
- **Hard spread (`DoNotSchedule`):** guarantees spread, but a pod can't schedule when a zone is full or missing, including on kind.
- **Prometheus and Alertmanager replicas:** left at one. Two Prometheus replicas doubles the largest memory user, and metrics are lost with the cluster anyway. Argo CD and External Secrets are installed by the Cluster workflow, not Argo CD, so their HA setup is a later step.

## Consequences
- **A production session costs roughly $0.60 an hour**, against about $0.38 for study. The extra comes from two NAT gateways, a third node and Multi-AZ RDS.
- **The production profile hasn't been tested on EKS yet.** The account is still under the Free plan's organization policy (see [ADR 0015](0015-paid-plan-and-github-oidc.md)), which may also deny some of it.
- **In-cluster databases in production use three times the memory requests:** 768 MiB instead of 256 MiB each.
- **Services with one replica get no PodDisruptionBudget,** because one that allows no disruption would block node drains.
