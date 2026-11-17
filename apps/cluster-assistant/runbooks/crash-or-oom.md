---
name: crash-or-oom
description: A container keeps restarting (CrashLoopBackOff), was OOMKilled, or exits with an error code
tools: list_pods, get_pod_logs, get_events, get_resource, query_prometheus
---
# Crash loops and out-of-memory kills

**Look at:** `list_pods` for the container's last exit (`lastState`: reason and exit code) and restart count. Then `get_pod_logs` with `previous: true`, because the current container may have just started. `get_events` shows `BackOff`.

**Read the exit code:**
- `OOMKilled` (exit 137): the container went over its memory limit. By default a service requests 64Mi and has a **256Mi memory limit** (and requests 50m CPU). A `WebService` can set `spec.resources.memory`, from 32Mi to 4Gi, which becomes the limit and is requested too, so the node reserves it. Check whether the service sets it. If not, setting it is the fix. If the use keeps growing until every kill, more memory only delays it: that is a leak in the app. `query_prometheus` with `container_memory_working_set_bytes` shows which.
- Exit 137 or 143 without `OOMKilled`: killed from outside, such as a node drain or eviction, or by a failing liveness probe when the service has `spec.healthCheck`. Check `get_events` for `Liveness probe failed` (load `health-checks`) and for the node.
- Exit 1 or 2: the app stopped itself. The previous log says why. Common causes are a missing environment variable or a failed connection at startup.
- Exit 126 or 127: the command isn't executable or isn't found. Check the image's entrypoint.
- Exit 139: the process crashed (segfault).

**Platform-specific:**
- A service with `spec.database` gets `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` and `DATABASE_URL` (the last on Kubernetes). An app that crashes with a connection error may be blocked by its network policy (load `blocked-traffic`) or have a database problem (load `database-connection`).
- An app that needs an external API must have `allowInternet: true`. Without it, outbound calls time out, and some apps exit when they do.
- Memory use over time: `query_prometheus` with `container_memory_working_set_bytes{namespace="…",pod=~"…"}` shows whether it grows steadily (a leak) or jumps at startup.

**Fix:** the change goes in Git, in the service's `WebService` (`workloads/<team>/<service>/envs/<env>/webservice.yaml`, or `base/` for every environment), or in the app. Editing the live objects is reverted by Argo CD.
