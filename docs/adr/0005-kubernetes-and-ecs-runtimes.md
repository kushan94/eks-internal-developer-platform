# ADR 0005: Offer Kubernetes and ECS Fargate behind one API

**Status:** Accepted (2026-11-05)

## Context
Kubernetes suits teams that want its ecosystem, but ECS Fargate is simpler to run for ordinary web services. Developers should be able to choose without learning two sets of tools.

## Decision
- Add `spec.runtime` to `WebService`, with `kubernetes` as the default and `ecs` as the alternative.
- Use one Composition that builds either Kubernetes resources or ECS resources, based on that field.
- Keep the `WebService` in Kubernetes for both runtimes, so Git, Argo CD and Backstage work the same way.
- Supply account-specific AWS values through an `aws-platform` EnvironmentConfig that is not committed, because the repo is public.
- Add ECS services to private subnets, reachable only from inside the VPC until the traffic milestone.

## Consequences
- Developers get one form and one file format for both runtimes.
- Every new feature, such as databases, public URLs and metrics, has to be built for both runtimes.
- Kubernetes services get internal DNS names, but ECS services don't until ECS Service Connect or a load balancer is added.
- An ECS service is marked ready once AWS has created it, not once its tasks are running.
- ECS needs AWS credentials, so the ECS runtime can't be tested end to end on kind alone.
