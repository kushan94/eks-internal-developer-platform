# Cluster assistant

Diagnoses a broken service. You give it a namespace (and optionally a service and what you're seeing), and a Claude model investigates with read-only tools: pods, events, logs, a fixed list of Kubernetes objects, and Prometheus. It can't change anything. See [ADR 0026](../../docs/adr/0026-cluster-assistant.md).

## Try it
```sh
make test-assistant      # unit tests, no cluster or API key
make test-diagnose       # breaks six workloads on kind, checks the tools show each cause (no API key)
ANTHROPIC_API_KEY=... scripts/diagnose-eval.sh   # also asks the model, which costs money
```

To run it against a cluster you already have:
```sh
kubectl proxy &
KUBE_API_URL=http://127.0.0.1:8001 PROMETHEUS_URL=http://localhost:9090 ANTHROPIC_API_KEY=... go run .
```
Then open http://localhost:8080. `go run . evidence <namespace>` prints what the tools see, without calling the model.

| Variable | Default | |
|---|---|---|
| `ANTHROPIC_API_KEY` | | Required to diagnose |
| `MODEL` | `claude-opus-5-5` | |
| `MAX_DIAGNOSES_PER_HOUR` | `30` | Spending cap |
| `KUBE_API_URL` | in-cluster | For local runs, with `kubectl proxy` |
| `PROMETHEUS_URL` | | Enables `query_prometheus` |
