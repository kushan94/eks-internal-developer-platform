---
name: argocd-out-of-sync
description: An Argo CD application is OutOfSync, Degraded, Progressing for a long time, or shows a ComparisonError or SyncError
tools: get_resource, list_pods, get_events
---
# Argo CD applications

Read the application with `get_resource`, kind `applications` (they are always in the `argocd` namespace). Look at `status.sync`, `status.health` and `status.conditions`.

**Names:** a team's single-file services are one app, `workload-<team>`, deploying to the namespace `<team>`. A service with environments has an app per environment, `workload-<team>-<service>-<env>`, deploying to `<team>-<env>`. Platform components (Loki, Alloy, OpenCost, Kyverno and so on) have their own apps.

**Argo CD fixes drift on its own.** Workload apps sync automatically with **self-heal and prune**: a live change that isn't in Git is reverted within moments, and a resource removed from Git is deleted. So `kubectl edit` doesn't stick, and an app that flips to OutOfSync and back is self-heal working.

**Health:**
- `Degraded`: a resource it manages is unhealthy. For a workload this is usually a `WebService` that isn't Ready (load `webservice-not-ready`), or pods that are failing.
- `Progressing`: still rolling out. Only worth chasing if it lasts many minutes.
- `Missing`: a resource in Git doesn't exist in the cluster.

**Sync problems (`conditions`):**
- `ComparisonError`: Argo CD can't read or render the source. Causes: a bad path or revision, the GitHub App credentials can't read the repo, or a manifest that doesn't build (a Kustomize error in an `envs/<env>` folder).
- `SyncError` with an admission message: the cluster refused an object, for example a Kyverno policy. The message names the policy.
- The `WebService` kind not found right after the platform is installed: the CRD appears once the platform API has synced. Syncs retry up to 20 times with backoff, so this clears by itself during bootstrap.
- Kyverno is compared with server-side diff, because its chart renders CRDs with empty labels. An OutOfSync on Kyverno that never resolves is something else.

**Fix:** the answer is in Git, on `main`: fix the manifest the error names. If the app is stuck on a transient error, a refresh or sync from the Argo CD UI re-runs it, but no change made to the live cluster survives.
