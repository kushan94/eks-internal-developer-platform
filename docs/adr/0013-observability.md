# ADR 0013: Metrics with Prometheus, Grafana and one dashboard per service

**Status:** Accepted (2026-11-10)

## Context
Developers can create services, but can't see how they behave: CPU, memory, restarts, or the app's own metrics. Backstage's Kubernetes tab skipped metrics because the cluster had no metrics-server. The cluster is rebuilt every session, so long-term storage isn't needed, and the nodes are small.

## Decision
- **metrics-server** on every cluster, for `kubectl top` and the CPU and memory columns in Backstage's Kubernetes tab.
- **kube-prometheus-stack** (Prometheus Operator, Prometheus, Grafana, kube-state-metrics, node-exporter) on every cluster.
  - Alertmanager is off until alerts have somewhere to go.
  - Prometheus keeps 2 days on an emptyDir, with a 1.5 GiB memory limit.
  - It picks up `PodMonitor`s and `ServiceMonitor`s from every namespace.
- **Service metrics:** `spec.metrics` on a `WebService` (`path`, and `port` if it differs from the service port) makes the composition add a named container port and a `PodMonitor`. Kubernetes runtime only.
- **One dashboard for every service:** the `WebService` dashboard shows running pods, restarts, memory, scrape health, and CPU, memory and network by pod. It finds a service's pods by their `backstage.io/kubernetes-id` label, which kube-state-metrics exports, so it also covers the service's in-cluster database and needs no per-service setup.
- **Grafana on EKS:** at `grafana.idp.skyforgelab.cloud` through the shared Gateway, with GitHub login only.
  - The login form is off. A JMESPath rule makes the users listed in `grafanaAdmins` admins, and `role_attribute_strict` refuses everyone else.
  - The OAuth app's credentials live in Secrets Manager and reach Grafana through External Secrets.
- **Backstage:** every service links to its dashboard, including services created from the template.

## Alternatives considered
- **CloudWatch Container Insights:** less to run, but costs per metric and doesn't work on kind.
- **Grafana behind port-forward only:** nothing exposed, but Backstage's links wouldn't work.
- **Reusing the Backstage GitHub App for Grafana login:** Grafana reads the user's email, which the app can't do without another permission. A separate OAuth app is simpler.

## Consequences
- **Memory:** the stack needs about 1.5–2 GiB. On kind it filled an 8 GB Colima VM shared with another cluster until that cluster was paused.
- **No history across sessions:** metrics disappear with the cluster.
- **ECS services have no metrics** in Prometheus. CloudWatch is the place for them later.
- **One manual step:** creating a GitHub OAuth app can't be done through an API.
