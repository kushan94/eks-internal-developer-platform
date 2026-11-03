# ADR 0003: Build locally first and keep EKS ephemeral

**Status:** Accepted (2026-11-03)

## Context
This is a personal study project, so idle AWS spend is the main risk. Most of the platform APIs can be built and tested without AWS.

## Decision
- Develop on kind, and use EKS only for work that needs AWS.
- Create the EKS cluster with Terraform at the start of a session and destroy it at the end.
- Use one AWS account, one cluster and one NAT gateway on Spot nodes.
- Use standard node groups rather than EKS Auto Mode, so we learn Karpenter and the AWS Load Balancer Controller directly.

## Consequences
- The setup must be fully reproducible, which is also useful for article readers.
- This is not a highly available production design, and the article must say so.
