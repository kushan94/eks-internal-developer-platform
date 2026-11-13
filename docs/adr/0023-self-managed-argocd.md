# ADR 0023: Argo CD manages itself and External Secrets after bootstrap

**Status:** Accepted (2026-11-13)

## Context
The Cluster workflow installs Argo CD and External Secrets with Helm, because Argo CD needs both before it can read the private repo. After that, nothing kept them in line with Git. Upgrading meant editing chart versions in the Makefile and running it by hand against each cluster, which is the kind of change GitOps exists to avoid.

## Decision
- **The bootstrap stays.** `make platform-bootstrap` still installs both first.
- **Then two Applications in the root chart keep them in line with Git:**
  - `argocd`, on every cluster, adopts the Helm release the bootstrap made (same release name).
  - `external-secrets`, on EKS only, where External Secrets runs.
- **One source of truth.**
  - Chart versions live in `gitops/root/values.yaml`, which the Makefile reads for the bootstrap.
  - Argo CD's settings stay in `platform/bootstrap/argocd-values.yaml`. The `argocd` app reads that same file from Git as a second source, so the bootstrap and Argo CD can't drift apart.
- **Built so mistakes can't remove Argo CD:**
  - No pruning, so a bad render can't delete Argo CD's own parts.
  - No resources finalizer, so deleting the app leaves Argo CD installed.
  - Both apps use the `default` project, like the root application, because the `platform` project doesn't allow the `argocd` and `external-secrets` namespaces.
  - Server-side apply, because Argo CD's CRDs are too large for client-side apply. Server-side diff too, because both charts have fields filled in at runtime: the server's secret key, Backstage's token, and webhook certificates.
- **Testing,** on a throwaway kind cluster with Argo CD installed exactly as `make argocd` does, and this branch served from a local Git server:
  - The `argocd` app adopted the release: Synced and Healthy in about 60 seconds, with the same pods and no restarts. Only the chart's Redis secret hook ran again.
  - A setting committed to `argocd-values.yaml` reached Argo CD's own config in about 30 seconds.
  - After the commit was removed, Argo CD returned to the previous value and settled at Synced and Healthy, with nothing out of sync.

## Alternatives considered
- **Leave both outside GitOps:** simple, but upgrades stay manual, and nothing notices when someone changes them by hand.
- **Install Argo CD with Terraform's Helm provider:** ties the cluster's contents to Terraform runs, which Argo CD replaced for everything else.
- **Let the root app's chart render Argo CD directly instead of a separate Application:** mixes the app-of-apps with the thing running it, and makes a bad change to the root chart riskier.

## Consequences
- **Upgrades are pull requests:** change `argocd.chartVersion` or `externalSecrets.chartVersion` and merge. A broken Argo CD release can still stop Argo CD from syncing the fix, so recovery means running `make argocd` with the previous version.
- **The GitHub credential template and ClusterSecretStore are still applied by the bootstrap,** not by Argo CD, since Argo CD needs them to read Git in the first place.
- **The `external-secrets` app hasn't been tested yet.** It needs EKS, where External Secrets runs.
