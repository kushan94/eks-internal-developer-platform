# Cluster dashboard and assistant

A dashboard for the cluster, with an assistant that diagnoses problems. Everything is read-only. See [ADR 0026](../../docs/adr/0026-cluster-assistant.md).

**The dashboard** has five tabs. The header shows an "N need attention" pill and a count on each tab, so a problem is visible whichever tab you are on.
- **Overview:** summary cards, capacity (requested against allocatable), last-hour charts when `PROMETHEUS_URL` is set, everything that needs attention (worst first, each with a **Diagnose** button), and the latest warnings.
- **Workloads:** namespaces as tiles coloured by health (click one for its WebServices, deployments, pods and warnings), and a searchable list of every pod.
- **Nodes:** zone, instance type, version and utilisation of each node, and the control plane's version against the nodes' (with a hint when nodes lag).
- **Delivery:** Argo CD applications.
- **Events:** every warning event, with the most common reasons as filter chips.

Tabs have their own addresses (`#/nodes`, `#/workloads?ns=shop`), so you can share a link to a view.

**The assistant** takes a namespace, a pod or a service and what you're seeing. A Claude model investigates with read-only tools (pods, events, logs, a fixed list of objects, Prometheus) and the page shows each step as it happens, then the cause, the evidence and the fix. It calls the Claude API, so each diagnosis costs money, and it starts only when you press Run.

## Try it
```sh
scripts/dashboard-demo.sh   # a kind cluster with healthy and broken services, then open http://localhost:18080
ANTHROPIC_API_KEY=... scripts/dashboard-demo.sh   # also lets you run the assistant
```

## Test it
```sh
make test-assistant      # unit tests, no cluster or API key
make test-diagnose       # breaks seven workloads on kind, checks the tools show each cause, then dry-runs the model comparison against a stand-in API (no key, no cost)
make test-dashboard      # browser tests: every tab, deep links, keyboard, the assistant panel. Needs Chrome and scripts/dashboard-demo.sh running
ANTHROPIC_API_KEY=... scripts/diagnose-eval.sh --compare   # asks the real model, without and with runbooks. Costs money, capped by EVAL_BUDGET_USD (default 5)
```

## Run it against a cluster you already have
```sh
kubectl proxy &
KUBE_API_URL=http://127.0.0.1:8001 PROMETHEUS_URL=http://localhost:9090 ANTHROPIC_API_KEY=... go run .
```
Then open http://localhost:8080. `go run . evidence <namespace>` prints what the tools see, without calling the model.

## Runbooks
The assistant can load **runbooks** from [`runbooks/`](runbooks/): short guides to common failures, written for this platform. They say what the composition sets, which policies apply, how to tell similar causes apart, and what the fix is in Git. It sees only their names and descriptions at first, and loads one when the symptoms match, so the prompt stays small as the set grows. The page shows each load in the timeline.

Current runbooks: `crash-or-oom`, `image-or-admission`, `pending-or-unschedulable`, `missing-secret-or-config`, `blocked-traffic`, `webservice-not-ready`, `argocd-out-of-sync`, `node-problems`, `database-connection`.

To add or change one, edit the file (front matter: `name`, `description`, `tools`), and run `make test-assistant`. It checks the format, that the tools named exist, and, with `scripts/check-runbooks.sh`, that what the runbook says about the platform is still true: the `WebService` fields, the resource sizes, the policy names, and the messages the composition emits. A runbook that goes stale fails the check. `RUNBOOKS=off` runs the assistant without them, to measure what they add.

## Limits on the assistant
A diagnosis costs money, so there are limits. The assistant's page shows today's spend against the cap.
- **Per diagnosis:** at most 12 model calls and `MAX_TOKENS_PER_DIAGNOSIS` tokens in all. Once 70% of the budget is used, or on the last call, the assistant can't use more tools and is told to answer from what it has. You get a partial answer marked as partial, not nothing.
- **Per day:** `MAX_DAILY_SPEND_USD`, estimated from token counts at list prices. When it's reached, new diagnoses are refused until midnight UTC. It is kept in memory, so a restart resets it. Every diagnosis is also logged with its cost.
- **Per hour and at once:** `MAX_DIAGNOSES_PER_HOUR` and `MAX_CONCURRENT_DIAGNOSES`.
- **Repeats are free:** the same question about the same pod, service or namespace within `DIAGNOSIS_CACHE_MINUTES` is answered from memory, and doesn't use any limit. Running again asks for a fresh one.
- **A model whose price isn't known** is priced as the most expensive one, so the cap errs towards stopping early. Set `PRICE_INPUT_PER_MTOK` and `PRICE_OUTPUT_PER_MTOK` if prices change.

These are estimates and guards, not a billing system. The Anthropic Console is the record of what you were charged. Set a spend limit there too.

| Variable | Default | |
|---|---|---|
| `ANTHROPIC_API_KEY` | | Needed for the assistant. The dashboard works without it |
| `MODEL` | `claude-opus-5-5` | |
| `MAX_TOKENS_PER_DIAGNOSIS` | `150000` | Input and output tokens across all calls |
| `MAX_DAILY_SPEND_USD` | `5` | `0` means no cap |
| `MAX_DIAGNOSES_PER_HOUR` | `30` | |
| `MAX_CONCURRENT_DIAGNOSES` | `3` | |
| `DIAGNOSIS_CACHE_MINUTES` | `5` | `0` turns the cache off |
| `KUBE_API_URL` | in-cluster | For local runs, with `kubectl proxy` |
| `PROMETHEUS_URL` | | Enables the charts and `query_prometheus` |

The page has no login yet. Don't expose it.
