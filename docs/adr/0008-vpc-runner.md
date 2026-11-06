# ADR 0008: Set up clusters from a GitHub runner inside the VPC

**Status:** Accepted (2026-11-06)

## Context
After Terraform creates EKS, the cluster still needs Argo CD, External Secrets and the GitOps root app. GitHub's hosted runners can't reach the API, because its public endpoint only allows the admin's IP. The options were to allow each runner's IP temporarily, to open the endpoint to the internet, or to run a runner inside the VPC.

## Decision
- **The runner:** a self-hosted runner on a `t3.small` instance (Free Tier-eligible) in a private subnet. Terraform creates it only with EKS, so the nightly destroy removes it too.
- **API access:** through the private endpoint. The cluster security group allows port 443 only from the runner's security group, and the runner's IAM role is a cluster admin.
- **AWS credentials:** the instance role, which can read the runner app secret, describe the cluster and read Terraform state. There are no AWS keys on the runner.
- **Registration:** a second GitHub App, `<owner>-idp-runner`, with *Administration: write*, installed only on the platform repo. At boot, the instance reads the app key from Secrets Manager, signs a JWT and gets a registration token, so no token passes through Terraform or user data.
- **Hardening:** no inbound rules, IMDSv2 required, and debug access through SSM Session Manager.
- **The Cluster workflow:** runs after a successful Infrastructure run, or by hand. A job on a hosted runner first checks that a cluster exists, so plan and destroy runs skip setup instead of queueing for a runner that doesn't exist. Setup runs the same `make` targets used locally and passes only when every Argo CD application is Synced and Healthy.

## Consequences
- The cluster API never needs to be reachable from GitHub's network.
- **Fork pull requests:** GitHub advises against self-hosted runners on public repos, because a fork's pull request could run code on them. While the repo is private, that risk doesn't apply. Before making it public, require approval for workflows from outside contributors.
- **Stale runners:** destroyed runners stay listed as offline in GitHub until it removes them automatically, after about 14 days.
- **Cost and time:** the runner adds about $0.02 an hour to an EKS session, and a few minutes of boot time before the Cluster workflow can start.
