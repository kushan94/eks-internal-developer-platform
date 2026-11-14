# Cluster dashboard and assistant

A dashboard for the cluster, with an assistant that diagnoses problems. Everything is read-only. See [ADR 0026](../../docs/adr/0026-cluster-assistant.md).

**The dashboard** shows what a person checks first when something is wrong:
- Summary cards: nodes ready, pods healthy, deployments available, Argo CD apps, warning events, restarts.
- Capacity: CPU, memory and pods requested against what the nodes can allocate, and the Kubernetes versions of the control plane and nodes (with a hint when nodes lag).
- "Needs attention": every failing or unhealthy pod, node and Argo CD application, worst first, each with a **Diagnose** button.
- Namespaces as tiles coloured by health. Click one for its WebServices, deployments, pods and warnings.
- Nodes (zone, instance type, version, utilisation), Argo CD applications, recent warnings.
- Last-hour charts for CPU, memory, restarts and pods not ready, when `PROMETHEUS_URL` is set.

**The assistant** takes a namespace, a pod or a service and what you're seeing. A Claude model investigates with read-only tools (pods, events, logs, a fixed list of objects, Prometheus) and the page shows each step as it happens, then the cause, the evidence and the fix. It calls the Claude API, so each diagnosis costs money, and it starts only when you press Run.

## Try it
```sh
scripts/dashboard-demo.sh   # a kind cluster with healthy and broken services, then open http://localhost:18080
ANTHROPIC_API_KEY=... scripts/dashboard-demo.sh   # also lets you run the assistant
```

## Test it
```sh
make test-assistant      # unit tests, no cluster or API key
make test-diagnose       # breaks six workloads on kind, checks the tools show each cause (no API key)
ANTHROPIC_API_KEY=... scripts/diagnose-eval.sh   # also asks the model, which costs money
```

## Run it against a cluster you already have
```sh
kubectl proxy &
KUBE_API_URL=http://127.0.0.1:8001 PROMETHEUS_URL=http://localhost:9090 ANTHROPIC_API_KEY=... go run .
```
Then open http://localhost:8080. `go run . evidence <namespace>` prints what the tools see, without calling the model.

| Variable | Default | |
|---|---|---|
| `ANTHROPIC_API_KEY` | | Needed for the assistant. The dashboard works without it |
| `MODEL` | `claude-opus-5-5` | |
| `MAX_DIAGNOSES_PER_HOUR` | `30` | Spending cap |
| `KUBE_API_URL` | in-cluster | For local runs, with `kubectl proxy` |
| `PROMETHEUS_URL` | | Enables the charts and `query_prometheus` |

The page has no login yet. Don't expose it.
