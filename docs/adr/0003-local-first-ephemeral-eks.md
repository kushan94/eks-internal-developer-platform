# ADR 0003: Build locally first and keep EKS ephemeral

**Status:** Accepted (2026-11-03), updated 2026-11-05 for the AWS Free plan

## Context
This is a personal study project, so idle AWS spend is the main risk. Most of the platform APIs can be built and tested without AWS.

## Decision
- Develop on kind, and use EKS only for work that needs AWS.
- Create the EKS cluster with Terraform at the start of a session and destroy it at the end.
- Use one AWS account in eu-north-1, with one cluster and one NAT gateway.
- Use an on-demand managed node group, because the account is on the AWS Free plan, which denies Spot instances.
- Use Pod Identity rather than IRSA, because the Free plan denies creating OIDC providers.
- Avoid Karpenter and EKS Auto Mode while on the Free plan, because it denies `ec2:CreateFleet`, which they depend on.

## Consequences
- The setup must be fully reproducible, which is also useful for article readers.
- This is not a highly available production design, and the article must say so.
- Upgrading to the Paid plan would allow Spot nodes and Karpenter again, and any remaining credits carry over.
