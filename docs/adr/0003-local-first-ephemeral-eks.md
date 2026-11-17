# ADR 0003: Build locally first and keep EKS ephemeral

**Status:** Accepted (2026-11-03), updated 2026-11-05 for the AWS Free plan

## Context
This is a personal study project, so idle AWS spend is the main risk. Most of the platform APIs can be built and tested without AWS.

## Decision
- Develop on kind, and use EKS only for work that needs AWS.
- Create the EKS cluster with Terraform at the start of a session and destroy it at the end.
- Use one AWS account in eu-north-1, with one cluster and one NAT gateway.
- Use an on-demand managed node group of `m7i-flex.large` instances. The account is on the AWS Free plan, which denies Spot instances and only allows Free Tier-eligible instance types. In eu-north-1, `m7i-flex.large` is the only eligible type with 8 GiB of memory.
- Use Pod Identity rather than IRSA, because the Free plan denies creating OIDC providers.
- Avoid Karpenter and EKS Auto Mode while on the Free plan, because it denies `ec2:CreateFleet`, which they depend on.

## Consequences
- The setup must be fully reproducible, which is also useful for article readers.
- This is not a highly available production design, and the article must say so.
- Upgrading to the Paid plan would allow Spot nodes and Karpenter again, and any remaining credits carry over.

## Update (2026-11-17): CreateFleet was never blocked
The decision above avoids Karpenter and EKS Auto Mode because the Free plan "denies `ec2:CreateFleet`". That came from policy simulator runs without a region. The organization's policy depends on the region, and without `aws:RequestedRegion` the simulator reports every regional action as denied, even `eks:CreateCluster` for an administrator. With the region supplied (`eu-north-1`), `ec2:CreateFleet` is allowed. Karpenter and Auto Mode haven't been tried, and nothing known blocks them.

What the policy does deny, with the region supplied, is the creation of ways to sign in to the account: `iam:CreateOpenIDConnectProvider`, `iam:CreateSAMLProvider`, `sso:CreateInstance`, `rolesanywhere:CreateTrustAnchor` and account aliases, and also `ec2:RequestSpotInstances`. It refuses requests to regions other than `eu-north-1`. The account is a member of an organization it doesn't manage, so that policy can't be read or changed from here.

