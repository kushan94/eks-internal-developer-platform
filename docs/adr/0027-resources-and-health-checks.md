# ADR 0027: Let a service set its resources and say how to check it is healthy

**Status:** Accepted (2026-11-16)

## Context
Writing runbooks for the diagnostic assistant meant writing down what the platform really does for a service, and two things didn't survive it:
- **Resources were fixed.** Every service requested 50m of CPU and 64Mi of memory and had a 256Mi memory limit. A `WebService` had no field to change them, so a service that needed more memory couldn't ask for it, and the only fix for an out-of-memory kill was to change the composition.
- **Nothing checked health.** The composition added no readiness or liveness probes. A pod counted as ready the moment its container started, so a service that wasn't listening yet, or had hung, still received traffic, and a rolling update could replace a working copy with a broken one.

## Decision
- **`spec.resources`** (Kubernetes runtime only):
  - `cpu` is the request, from 10m to 2 cores. There is still no CPU limit, because a limit throttles a busy service even when the node has spare CPU. The request is what the scheduler reserves and what autoscaling measures use against.
  - `memory` is the limit, from 32Mi to 4Gi, and **the same amount is requested**, so the node reserves what the service may use. That keeps nodes from being over-committed on memory, which the old 64Mi-request, 256Mi-limit default allowed.
  - Leave it out and nothing changes: 50m, 64Mi requested, 256Mi limit.
  - Values can be strings (`250m`, `512Mi`) or plain numbers, which is how YAML reads `cpu: 1`. A fraction of a core is written `500m`, not `0.5`.
  - The bounds are CEL rules in the XRD, so a service can't ask for 100 cores, and the refusal says what is allowed.
- **A default readiness check for every service:** a TCP check on the service's port, so a pod is ready when its port accepts connections. It adds no liveness probe, because restarting a container on a bare port check does more harm than good.
- **`spec.healthCheck.path`** (Kubernetes runtime only) switches to three HTTP probes on that path:
  - **readiness:** a 2xx or 3xx answer means ready;
  - **liveness:** a container that stops answering for 30 seconds is restarted;
  - **startup:** a slow start gets up to a minute before liveness can restart it.
- **ECS:** `resources` and `healthCheck` fail with a message saying they are Kubernetes-only for now, like `autoscaling`.
- **Testing:**
  - `make test` renders the defaults, a service with its own resources, one with plain-number quantities, and one with a health check, and asserts on the rendered Deployment. It checks that six out-of-range values and a path without a slash are refused, that the ECS guard fires with its reason, and that I broke the composition six ways and a test failed each time.
  - `make test-health` runs on a throwaway kind cluster, against a real API server and real pods. It found a bug that all the offline checks passed: **the API server refused the schema I had written for plain numbers** (an `anyOf` carrying `maxLength` isn't a structural schema), which would have stopped Crossplane creating the CRD for everyone. It also checks that a pod on the default port check becomes ready, that a path answering 200 does, and that a path answering 404 stays not ready, with an event naming the 404, and is restarted once the startup window passes.

## Alternatives considered
- **T-shirt sizes (small, medium, large):** simpler to write, but they hide the trade-off and need a table to look up, and a service that needs 600Mi fits none of them.
- **Separate request and limit fields:** more flexible, and more ways to get it wrong. Requesting what the limit allows is the safe default, and an escape hatch can be added if someone needs to burst.
- **An HTTP probe on `/` by default:** a better check, but a service with no route on `/` would never become ready. The TCP check is safe for any service that listens.
- **A liveness probe by default:** would restart services that are slow but fine. It is opt-in with a path.
- **Bounds in a Kyverno policy:** the refusal would come later, from Crossplane's apply, instead of when the `WebService` is written.
- **Vertical Pod Autoscaler:** sizes by observed use. It is worth having, but it needs history and adds a controller, and it doesn't replace letting a developer say what they need.

## Consequences
- **Every existing service gets a readiness probe at its next sync,** so each rolls once. All the services in this repo listen on the port they declare. A service that doesn't now shows as not ready, which was true before and unseen.
- **Setting `memory` reserves that much on a node,** unlike the default, which reserves 64Mi and lets a service burst to 256Mi. On the two small nodes of the study profile, a few services asking for 1Gi use real capacity.
- **A health path should check the service itself, not its dependencies.** If it fails whenever the database is down, liveness restarts every copy in a loop.
- **The caps are a platform decision:** 2 cores and 4Gi. A service that needs more means changing the XRD, which is a reason to talk about it.
- **Not on EKS yet.** The probes and sizes ran on kind. On EKS the load balancer's own target health checks are separate and unchanged.
- **The Backstage template doesn't offer the fields yet,** so they are written by hand.
- **The assistant's runbooks change with it.** `crash-or-oom`, `pending-or-unschedulable`, `node-problems` and `webservice-not-ready` no longer say that a service can't change its resources, and a `health-checks` runbook is new, since the platform can now produce probe failures. The drift check verifies the defaults, the bounds and the probe timings, so it fails when they change again.
