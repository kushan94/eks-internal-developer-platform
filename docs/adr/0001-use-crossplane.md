# ADR 0001: Use Crossplane for platform APIs

**Status:** Accepted (2026-11-03)

## Context
Developers need a simple way to request an application and the cloud resources it depends on. The main options were Crossplane v2, or ACK + kro through EKS Capabilities.

## Decision
Use Crossplane v2 with namespaced composite resources and composition functions.

## Consequences
- We run and upgrade Crossplane and its providers ourselves, which is more work but teaches more.
- The APIs are not tied to AWS.
- Providers can use a lot of cluster memory, so install only the AWS provider families we need.
