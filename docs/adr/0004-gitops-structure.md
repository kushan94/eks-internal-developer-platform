# ADR 0004: Structure GitOps with a root application

**Status:** Accepted (2026-11-03)

## Context
Argo CD should deliver the whole platform from Git, with as little applied by hand as possible. Backstage will later create services by opening pull requests, so adding a service needs to be a small, predictable change.

## Decision
- Apply one root application by hand. It renders the `gitops/root` Helm chart, which defines every other application.
- Install Argo CD itself with Helm, outside this flow.
- Generate one application and namespace per directory under `workloads/` with an ApplicationSet.
- Handle dependency order with retries and `SkipDryRunOnMissingResource`, not sync waves.
- Pass the repo URL as a value, so that moving from the local Git server to a hosted repo changes one setting.

## Consequences
- A new service only needs a new file in a new or existing folder, which is simple for a Backstage template to generate.
- Applications may show errors briefly while dependencies are installing, until a retry succeeds.
- Argo CD is not managed by Argo CD yet, so its upgrades are still manual.
- Removing a workload folder leaves its namespace behind.
