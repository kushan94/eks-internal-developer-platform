# ADR 0007: Give Argo CD repo access through a GitHub App

**Status:** Accepted (2026-11-06)

## Context
The repo is private, and Argo CD should be able to deploy from any approved repo, not just this one. Clusters are destroyed every night, so any credential that lives only in a cluster is lost each time.

## Decision
- **Credential:** a GitHub App with read-only Contents access, installed on the repos Argo CD may read. Argo CD gets installation tokens that expire after an hour.
- **Storage:** the app's ID, installation ID and private key live in the AWS Secrets Manager secret `idp/argocd/github-app`, created by the bootstrap stack so it survives the nightly destroy. Its value is set with the AWS CLI, so the key never enters Terraform state.
- **Delivery:** External Secrets Operator reads the secret through EKS Pod Identity, with an IAM role limited to `idp/argocd/*`, and writes an Argo CD credential template for `https://github.com/<owner>`. One template covers every repo the app can read.
- **Bootstrap:** Argo CD needs this credential before it can read Git, so `make platform-bootstrap` installs Argo CD and External Secrets with Helm, outside GitOps.
- **Other repos:** a file in `apps/` points Argo CD at a directory in another repo, so onboarding a repo is a reviewed pull request.
- **Guardrails:** two Argo CD projects.
  - `platform` is for platform components.
  - `workloads` is for teams. It can only create `WebService` resources, outside system namespaces, from repos under the owner.

## Consequences
- No personal tokens are involved, and the stored key never leaves AWS except into the cluster.
- The GitHub App has to be created in the GitHub web interface, and its private key rotated there.
- Argo CD and External Secrets aren't yet managed by Argo CD, so their upgrades go through the Makefile. ([ADR 0023](0023-self-managed-argocd.md) changes this.)
- GitHub's repo-scanning generator could discover repos automatically, but as far as we know it scans organizations rather than personal accounts, so onboarding stays explicit through `apps/`.
