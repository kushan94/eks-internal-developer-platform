---
name: health-checks
description: A pod is Running but not Ready, a readiness, liveness or startup probe fails, or a container is restarted because it stopped answering
tools: list_pods, get_events, get_pod_logs, get_resource
---
# Health checks

Every Kubernetes service has a readiness check. By default it is a **TCP check on the service's port**: the pod is ready once the port accepts connections. When the service sets `spec.healthCheck.path`, the platform uses three HTTP probes on that path instead:
- **readiness:** a 2xx or 3xx answer means ready. Three failures in a row, five seconds apart, make it not ready.
- **liveness:** 30 seconds of failures restart the container.
- **startup:** a slow start gets up to about a minute, and liveness can't restart it before that.

**Look at:** `list_pods` shows `Running` with ready `0/1` when readiness fails, and a rising restart count when liveness or startup does. `get_events` shows `Readiness probe failed`, `Liveness probe failed` or `Startup probe failed`, each with the reason. `get_pod_logs` shows what the app was doing.

**Read the reason:**
- `connection refused`: nothing is listening on the port. Compare `spec.port` with the port the app says it listens on in its log. This is the usual cause with the default check: the app listens on 3000 and the `WebService` says 8080.
- `HTTP probe failed with statuscode: 404`, or a 5xx: the path doesn't exist, or the app is failing. Compare `spec.healthCheck.path` with the app's routes.
- A timeout (`context deadline exceeded`): the path took more than two seconds. A path that does real work, such as querying a database, is too slow for a probe.
- Startup probe failures followed by a restart, over and over: the app needs more than a minute to start, or never starts. The log shows why. It looks like a crash loop (load `crash-or-oom`).
- Liveness restarts of an app that looks healthy: the path probably checks a dependency. When the database is down, every copy fails its probe and restarts in a loop. The path should check only that the process itself can answer.

**Effects:** a pod that isn't ready gets no traffic from its Service, and a Deployment without enough ready pods makes the `WebService` not Ready (load `webservice-not-ready`). A bad health path on a new image stalls the rollout: the new pods never become ready and the old ones keep serving, so compare the two ReplicaSets with `get_resource`.

**ECS services** don't have `healthCheck` (it is Kubernetes-only for now).

**Fix:** in the `WebService` in Git: correct `spec.port` or `spec.healthCheck.path`, or fix the app so it listens and answers. Don't remove the health check to make a pod ready: that hides the problem.
