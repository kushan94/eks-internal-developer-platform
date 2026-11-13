# ADR 0025: Cost per service with OpenCost

**Status:** Accepted (2026-11-13)

## Context
Teams could see what their services do, but not what they cost. Cost per service is how a platform shows teams the effect of their resource requests and replica counts, and it turns "the cluster is expensive" into "these three services are". The platform already collects the inputs: what each container is allocated, and labels that tie pods to services and environments.

## Decision
- **OpenCost** (chart 2.5.33, OpenCost 1.121.3) runs in `monitoring`, and reads from and writes to the platform's Prometheus.
  - It prices nodes from AWS's public price list on EKS, and from its defaults on kind.
  - Its UI is off; Grafana shows cost instead.
- **A recording rule, `webservice:cost_dollars_per_hour`,** sums each container's CPU and memory allocation at its node's hourly prices. It groups by `service` and `environment`, with the same labels as the dashboard and alerts. It includes the service's in-cluster database.
- **The WebService dashboard shows** cost per hour, a monthly estimate (× 730 hours), and cost per hour by environment.
- **Two OpenCost settings are required:**
  - `emitKsmV1Metrics: false`. By default OpenCost publishes its own copy of kube-state-metrics' metrics, including `kube_pod_labels`. Two copies make every join on pod labels ambiguous, and Prometheus refuses them. That broke the cost rule and **also the existing `WebServiceDown` and `WebServiceRestarting` alerts**.
  - An `emptyDir` at `/var/configs`. OpenCost stores price data there, and its container's filesystem is read-only. Without it, OpenCost had no node prices at all, which on EKS would have meant no AWS pricing either.
- **Testing:**
  - A promtool unit test checks the rule against costs worked out by hand: $0.0315 an hour for an app and its database in prod on one node, $0.0065 for dev on another. A pod without a service label isn't counted.
  - On a throwaway kind cluster with kube-prometheus-stack and OpenCost, the rule gave $0.008962 an hour for a pod with 0.25 CPU and 256 MiB. That's exactly the hand calculation at OpenCost's default prices. All rules stayed healthy.
  - That live test found both of the settings above. The unit test couldn't have, since it feeds the rule clean data.

## Alternatives considered
- **Kubecost:** OpenCost with more features, such as cloud bill reconciliation and savings advice, but its free tier has limits, and it brings its own Prometheus and UI.
- **AWS Split Cost Allocation Data for EKS:** cost per pod in the AWS Cost and Usage Report. It's accurate to the bill, but arrives a day later and needs Athena or another tool to read it. Clusters here live for hours.
- **Requests times a fixed price, in a dashboard:** no extra component, but it wouldn't know node types or prices.

## Consequences
- **Cost is what's allocated, not what's used.** A service that requests more than it needs pays for it, which is the point: it shows the effect of requests.
- **Shared costs aren't divided up:** the EKS control plane, the platform's own pods, NAT gateways, load balancers and RDS. The per-service figures add up to less than the bill.
- **On-demand list prices.** Credits, savings plans and discounts aren't applied.
- **Not tested on EKS yet,** where OpenCost reads AWS prices.
