---
name: webservice-not-ready
description: A WebService is not Ready or not Synced, was refused when applied, or Crossplane reports an error
tools: get_resource, list_pods, get_events
---
# A WebService that isn't Ready

Start with the `WebService` itself: `get_resource` with kind `webservices`. Its **`Synced`** and **`Ready`** conditions say where it is stuck.

**`Synced` is False: Crossplane couldn't create what the service needs.** The message gives the reason. The ones you'll meet:
- A Kyverno policy refused it: `prod-replicas` says "services in prod need at least 2 replicas" (with autoscaling, `minReplicas` counts, and `replicas` is ignored). Image and registry policies are covered by `image-or-admission`.
- The composition refused the spec: "resources and healthCheck are only available for the kubernetes runtime for now", "in-cluster databases are only available for the kubernetes runtime; use class: managed on ECS", "autoscaling is only available for the kubernetes runtime", "allowFrom, allowTo and allowInternet are only available for the kubernetes runtime", "public URLs are only available for the kubernetes runtime", or a database name longer than Postgres' 63 characters (`<namespace>-<name>`: shorten one).
- The platform is missing settings: "managed databases need managedPostgres.… in the managed-postgres or aws-platform EnvironmentConfig", "public WebServices need platform.domain and platform.gateway", "the ECS runtime needs aws.… in the aws-platform EnvironmentConfig". These are platform problems, not the developer's.

**`Synced` is True but `Ready` is False: the service was created but isn't up.** It becomes Ready when its Deployment has at least `minReplicas` (or `replicas`) available, which needs its pods to pass their readiness check: a TCP check on the service's port by default, or `spec.healthCheck.path` when set. Pods that are Running but not ready: load `health-checks`. Everything the composition makes is named after the service: the Deployment, Service, PodDisruptionBudget, NetworkPolicy, and when asked for, a HorizontalPodAutoscaler (`autoscaling`), PodMonitor (`metrics`) and HTTPRoute (`public`). A database adds `<service>-db`.
- Pods failing: `list_pods`, then load `crash-or-oom`, `image-or-admission`, `pending-or-unschedulable` or `missing-secret-or-config` for what you see.
- A database that isn't ready holds the service back: load `database-connection`.

**New services:** a minute or two of not-Ready is normal while the image pulls and a database is created. In-cluster databases take longer, and a managed database on EKS depends on the shared RDS server.

**Fix:** change the `WebService` in Git, in `workloads/<team>/<service>/envs/<env>/webservice.yaml` or `base/`. Don't edit the live object: Argo CD reverts it.
